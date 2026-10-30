import AppKit
import SopranoAgentsCore

/// How the diff list shows a hunk's lines: one column of old and new lines
/// (`unified`, titled Inline), or the old file on the left and the new one on
/// the right (`split`). App-wide, persisted in `AppStateStore.diffLayout`.
enum DiffLayout: String, Sendable {
    case unified
    case split

    var toggled: DiffLayout { self == .unified ? .split : .unified }
    var title: String { self == .unified ? "Inline" : "Split" }
}

/// One file's diff flattened into list rows: a header row per hunk followed
/// by its lines, capped at `lineLimit` lines. Files without text hunks
/// (binary, rename only, mode change, empty) carry a one-line `notice`.
/// Both layouts' rows are built once per load, off the main thread.
struct DiffDocument: Equatable, Sendable {
    enum Row: Hashable, Sendable {
        /// Header of `file.hunks[index]`.
        case hunk(Int)
        /// `file.hunks[hunk].lines[line]` (unified layout).
        case line(hunk: Int, line: Int)
        /// Split layout: `file.hunks[hunk].lines[old]` on the left and
        /// `…lines[new]` on the right; nil is a filler cell on that side.
        case pair(hunk: Int, old: Int?, new: Int?)
        /// A muted note inside the list (mode change, truncation).
        case notice(String)
    }

    /// A listed line: `file.hunks[hunk].lines[line]`.
    struct LineID: Hashable, Sendable {
        var hunk: Int
        var line: Int
    }

    static let lineLimit = 20_000

    var file: FileDiff?
    /// Unified layout rows.
    var rows: [Row]
    /// Row index of each listed hunk's header; hunks past the cap are absent.
    var hunkRows: [Int]
    /// Split layout rows: the same hunks and notices, lines paired side by side.
    var splitRows: [Row]
    var splitHunkRows: [Int]
    /// Replaces the list when the file has nothing to show line by line.
    var notice: String?
    var totalLines: Int
    var isTruncated: Bool
    var additions: Int
    var deletions: Int
    /// Widest listed line of each side in display columns (`columns(of:)`);
    /// sizes the horizontal scroll of the code text.
    var oldColumns = 0
    var newColumns = 0
    /// Word emphasis (Soprano's `GitDiffLayout.changedRanges`): each removed
    /// line that faces an added line in the split pairing (the n-th removed
    /// line of a change block and its n-th added line) maps to the UTF-16
    /// range of its raw text that differs from the other line. Lines that
    /// differ throughout, equal pairs and unpaired lines are absent, as is a
    /// side whose differing range is empty (a pure insertion or deletion
    /// inside the line). Both layouts use the same ranges.
    var changedRanges: [LineID: NSRange] = [:]

    /// What a "\ No newline at end of file" line shows.
    static let noNewlineText = "No newline at end of file"

    static let empty = DiffDocument(
        file: nil, rows: [], hunkRows: [], splitRows: [], splitHunkRows: [], notice: nil, totalLines: 0,
        isTruncated: false, additions: 0, deletions: 0
    )

    /// Number of hunks the list shows (and j/k visits).
    var hunkCount: Int { hunkRows.count }

    func rows(in layout: DiffLayout) -> [Row] {
        layout == .unified ? rows : splitRows
    }

    func hunkRows(in layout: DiffLayout) -> [Int] {
        layout == .unified ? hunkRows : splitHunkRows
    }

    /// The file titled `title` (new or old path), else the only/first file.
    static func pick(_ files: [FileDiff], title: String) -> FileDiff? {
        files.first(where: { $0.newPath == title || $0.oldPath == title }) ?? files.first
    }

    /// Picks the file titled `title` (new or old path), else the only/first file.
    static func build(files: [FileDiff], title: String, lineLimit: Int = DiffDocument.lineLimit) -> DiffDocument {
        guard let file = pick(files, title: title) else {
            var document = DiffDocument.empty
            document.notice = "No changes."
            return document
        }
        var additions = 0
        var deletions = 0
        var totalLines = 0
        for hunk in file.hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                switch line.kind {
                case .added: additions += 1
                case .removed: deletions += 1
                case .context, .noNewlineMarker: break
                }
            }
        }
        var document = DiffDocument(
            file: file, rows: [], hunkRows: [], splitRows: [], splitHunkRows: [], notice: nil, totalLines: totalLines,
            isTruncated: false, additions: additions, deletions: deletions
        )
        if file.isBinary {
            document.notice = "Binary file. There is no text diff to show."
            return document
        }
        let modeChange = modeChangeText(file)
        if file.hunks.isEmpty {
            document.notice = emptyNotice(for: file, modeChange: modeChange)
            return document
        }
        var rows: [Row] = []
        rows.reserveCapacity(min(totalLines, lineLimit) + file.hunks.count + 2)
        if let modeChange {
            rows.append(.notice(modeChange))
        }
        var hunkRows: [Int] = []
        var shown = 0
        hunks: for (hunkIndex, hunk) in file.hunks.enumerated() {
            guard shown < lineLimit else {
                document.isTruncated = true
                break
            }
            hunkRows.append(rows.count)
            rows.append(.hunk(hunkIndex))
            for lineIndex in hunk.lines.indices {
                guard shown < lineLimit else {
                    document.isTruncated = true
                    break hunks
                }
                rows.append(.line(hunk: hunkIndex, line: lineIndex))
                shown += 1
            }
        }
        if document.isTruncated {
            rows.append(.notice(
                "Large diff: showing the first \(lineLimit.formatted()) of \(totalLines.formatted()) lines."
            ))
        }
        document.rows = rows
        document.hunkRows = hunkRows
        (document.splitRows, document.splitHunkRows) = splitRows(from: rows, file: file)
        document.changedRanges = changedRanges(splitRows: document.splitRows, file: file)
        for case let .line(hunk, index) in rows {
            let line = file.hunks[hunk].lines[index]
            let width = columns(of: line)
            switch line.kind {
            case .removed:
                document.oldColumns = max(document.oldColumns, width)
            case .added:
                document.newColumns = max(document.newColumns, width)
            case .context, .noNewlineMarker:
                document.oldColumns = max(document.oldColumns, width)
                document.newColumns = max(document.newColumns, width)
            }
        }
        return document
    }

    /// Columns a line takes as the row draws it: cut at
    /// `DiffDocument.maximumDrawnLength` characters, tabs as four columns, and
    /// CJK and emoji (which fall back to wider fonts) as two.
    /// Longest prefix of a line a row draws (minified files would otherwise stall layout).
    static let maximumDrawnLength = 2000

    static func columns(of line: DiffLine) -> Int {
        if line.kind == .noNewlineMarker { return noNewlineText.count }
        var columns = 0
        for character in line.text.prefix(maximumDrawnLength) {
            if character == "\t" {
                columns += 4
            } else if let scalar = character.unicodeScalars.first, scalar.value >= 0x2E80 {
                columns += 2
            } else {
                columns += 1
            }
        }
        return columns
    }

    /// Soprano's side-by-side pairing over the unified rows (so the line cap
    /// applies identically): context lines face themselves; in each change
    /// block (removed lines, then added lines) the n-th removed line faces the
    /// n-th added one and the shorter side gets fillers. A "no newline" marker
    /// stays on the side of the line it follows (both sides after context).
    static func splitRows(from rows: [Row], file: FileDiff) -> (rows: [Row], hunkRows: [Int]) {
        var result: [Row] = []
        result.reserveCapacity(rows.count)
        var hunkRows: [Int] = []
        var removed: [Int] = []
        var added: [Int] = []
        var blockHunk = 0
        var previous: DiffLine.Kind?
        func flush() {
            for pair in 0..<max(removed.count, added.count) {
                result.append(.pair(
                    hunk: blockHunk,
                    old: pair < removed.count ? removed[pair] : nil,
                    new: pair < added.count ? added[pair] : nil
                ))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for row in rows {
            switch row {
            case .hunk:
                flush()
                previous = nil
                hunkRows.append(result.count)
                result.append(row)
            case .notice:
                flush()
                result.append(row)
            case .pair:
                result.append(row)
            case let .line(hunk, index):
                let kind = file.hunks[hunk].lines[index].kind
                switch kind {
                case .context:
                    flush()
                    result.append(.pair(hunk: hunk, old: index, new: index))
                case .removed:
                    // A removed line after added ones starts the next block.
                    if !added.isEmpty { flush() }
                    blockHunk = hunk
                    removed.append(index)
                case .added:
                    blockHunk = hunk
                    added.append(index)
                case .noNewlineMarker:
                    switch previous {
                    case .removed: removed.append(index)
                    case .added: added.append(index)
                    case .context, .noNewlineMarker, nil:
                        flush()
                        result.append(.pair(hunk: hunk, old: index, new: index))
                    }
                    continue
                }
                previous = kind
            }
        }
        flush()
        return (result, hunkRows)
    }

    /// The word emphasis of every split pair that faces a removed line with an
    /// added one; context pairs, fillers and "no newline" markers carry none.
    static func changedRanges(splitRows rows: [Row], file: FileDiff) -> [LineID: NSRange] {
        var ranges: [LineID: NSRange] = [:]
        for case let .pair(hunk, old?, new?) in rows {
            let lines = file.hunks[hunk].lines
            let removed = lines[old]
            let added = lines[new]
            guard removed.kind == .removed, added.kind == .added,
                  let changed = changedRanges(old: removed.text, new: added.text) else { continue }
            if changed.old.length > 0 { ranges[LineID(hunk: hunk, line: old)] = changed.old }
            if changed.new.length > 0 { ranges[LineID(hunk: hunk, line: new)] = changed.new }
        }
        return ranges
    }

    /// Soprano's intraline rule: the differing middle of two lines that share
    /// a prefix or a suffix, as UTF-16 ranges in each, never splitting a
    /// surrogate pair; nil when the lines share neither end or are equal.
    static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange)? {
        let oldUnits = old.utf16
        let newUnits = new.utf16
        let oldCount = oldUnits.count
        let newCount = newUnits.count
        let shorter = min(oldCount, newCount)
        var prefix = 0
        var lastShared: UTF16.CodeUnit = 0
        for (oldUnit, newUnit) in zip(oldUnits, newUnits) {
            guard oldUnit == newUnit else { break }
            lastShared = oldUnit
            prefix += 1
        }
        if prefix > 0, prefix < oldCount, UTF16.isLeadSurrogate(lastShared) {
            prefix -= 1
        }
        var suffix = 0
        var firstShared: UTF16.CodeUnit = 0
        for (oldUnit, newUnit) in zip(oldUnits.reversed(), newUnits.reversed()) {
            guard suffix < shorter - prefix, oldUnit == newUnit else { break }
            firstShared = oldUnit
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(firstShared) {
            suffix -= 1
        }
        let oldLength = oldCount - prefix - suffix
        let newLength = newCount - prefix - suffix
        guard prefix > 0 || suffix > 0, oldLength > 0 || newLength > 0 else { return nil }
        return (NSRange(location: prefix, length: oldLength), NSRange(location: prefix, length: newLength))
    }

    /// The word emphasis of `file.hunks[hunk].lines[line]`, nil when it has none.
    func changedRange(hunk: Int, line: Int) -> NSRange? {
        changedRanges[LineID(hunk: hunk, line: line)]
    }

    private static func modeChangeText(_ file: FileDiff) -> String? {
        guard let old = file.oldMode, let new = file.newMode, old != new else { return nil }
        return "File mode changed from \(old) to \(new)."
    }

    private static func emptyNotice(for file: FileDiff, modeChange: String?) -> String {
        switch file.kind {
        case .renamed, .copied:
            let verb = file.kind == .renamed ? "Renamed" : "Copied"
            let move = "\(file.oldPath ?? "?") → \(file.newPath ?? "?")"
            if let modeChange { return "\(verb) \(move). \(modeChange)" }
            return "\(verb) without content changes: \(move)."
        case .added where modeChange == nil:
            return "Empty file added."
        case .deleted where modeChange == nil:
            return "Empty file deleted."
        default:
            return modeChange ?? "No content changes."
        }
    }

    /// The hunk a row belongs to.
    func hunk(ofRow row: Int, in layout: DiffLayout = .unified) -> Int? {
        let rows = rows(in: layout)
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .hunk(index): return index
        case let .line(hunk, _), let .pair(hunk, _, _): return hunk
        case .notice: return nil
        }
    }

    /// The first row of hunk `index` that shows a change in `layout`: the
    /// first added or removed line (unified), or the first pair with one on
    /// either side (split). The current hunk's pencil tick sits on it.
    func firstChangedRow(ofHunk index: Int, in layout: DiffLayout) -> Int? {
        let rows = rows(in: layout)
        let hunkRows = hunkRows(in: layout)
        guard let file, hunkRows.indices.contains(index) else { return nil }
        let lines = file.hunks[index].lines
        func isChange(_ line: Int?) -> Bool {
            guard let line else { return false }
            return lines[line].kind == .added || lines[line].kind == .removed
        }
        for row in (hunkRows[index] + 1)..<rows.count {
            switch rows[row] {
            case let .line(hunk, line) where hunk == index:
                if isChange(line) { return row }
            case let .pair(hunk, old, new) where hunk == index:
                if isChange(old) || isChange(new) { return row }
            default:
                return nil
            }
        }
        return nil
    }

    /// The hunk as unified-diff text (header line plus prefixed lines), for copying.
    func text(ofHunk index: Int) -> String? {
        guard let file, file.hunks.indices.contains(index) else { return nil }
        let hunk = file.hunks[index]
        var lines = [Self.header(of: hunk)]
        for line in hunk.lines {
            switch line.kind {
            case .context: lines.append(" " + line.text)
            case .added: lines.append("+" + line.text)
            case .removed: lines.append("-" + line.text)
            case .noNewlineMarker: lines.append("\\ No newline at end of file")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func header(of hunk: DiffHunk) -> String {
        let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return hunk.section.isEmpty ? range : range + " " + hunk.section
    }
}
