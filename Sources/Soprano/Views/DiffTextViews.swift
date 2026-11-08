import AppKit

// MARK: - Document

/// One file's whole-file diff (`GitStatusReader.diff` reads every line as
/// context) prepared for Soprano Agents' diff list: both layouts, the syntax
/// colors of each side, and the counts the header shows. Built off the main
/// thread; a palette change only redraws.
struct SurfaceDiffDocument: Sendable {
    /// The file header's change glyph.
    enum Change: Sendable {
        case added
        case deleted
        case modified
    }

    /// Repository-relative path (the header and Copy path).
    let path: String
    let lines: [GitDiffLine]
    /// Stacked rows: each change's removed lines above its added ones.
    let unified: GitDiffLayout
    /// Split rows, old and new side row for row (fillers pad the shorter).
    let old: GitDiffLayout
    let new: GitDiffLayout
    let highlights: GitDiffHighlights
    let additions: Int
    let deletions: Int
    /// The largest line number either side shows.
    let maxLine: Int
    /// The widest line, in monospaced columns.
    let maxColumns: Int
    let change: Change

    init(path: String, lines: [GitDiffLine], language: CodeLanguage?) {
        self.path = path
        self.lines = lines
        unified = GitDiffLayout.inline(lines)
        let sides = GitDiffLayout.sideBySide(lines)
        old = sides.old
        new = sides.new
        highlights = GitDiffHighlights.compute(lines, language: language)
        var added = 0
        var removed = 0
        var context = 0
        var maxLine = 1
        var maxColumns = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: context += 1
            }
            maxLine = max(maxLine, line.oldNumber ?? 0, line.newNumber ?? 0)
            maxColumns = max(maxColumns, Self.columns(of: line.text))
        }
        additions = added
        deletions = removed
        self.maxLine = maxLine
        self.maxColumns = maxColumns
        change = context == 0 && removed == 0 ? .added : context == 0 && added == 0 ? .deleted : .modified
    }

    /// Columns `text` takes in a monospaced font, as the diff rows draw it.
    static func columns(of text: String) -> Int {
        DiffLine(kind: .context, text: text, oldNumber: nil, newNumber: nil).columns
    }

    /// The text a row draws: line breaks the text system would act on show as
    /// visible symbols of the same UTF-16 length, so token and emphasis offsets
    /// still apply.
    static func displayText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { lineBreakSymbols[$0] != nil }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(lineBreakSymbols[scalar] ?? scalar)
        }
        return String(scalars)
    }

    private static let lineBreakSymbols: [Unicode.Scalar: Unicode.Scalar] = [
        "\r": "\u{240D}", // ␍
        "\u{0B}": "\u{240B}", // ␋ vertical tab
        "\u{0C}": "\u{240C}", // ␌ form feed
        "\u{85}": "\u{2424}", // ␤ next line
        "\u{2028}": "\u{2424}", // ␤ line separator
        "\u{2029}": "\u{00B6}", // ¶ paragraph separator
    ]

    /// The changed words of a row, kept only when the line shares real content with its pair:
    /// at least 3 non-blank characters and a quarter of the line (Agents' rule). Two unrelated
    /// lines that merely share indentation or a closing ")" would otherwise light up whole.
    func emphasis(of row: GitDiffRow) -> NSRange? {
        guard let range = row.changedRange, range.length > 0, let index = row.lineIndex else { return nil }
        let text = lines[index].text as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        let outside = text.substring(to: range.location) + text.substring(from: NSMaxRange(range))
        let shared = outside.filter { !$0.isWhitespace }.count
        let total = (text as String).filter { !$0.isWhitespace }.count
        return shared >= 3 && shared * 4 >= total ? range : nil
    }

    /// The syntax tokens of a row's line as its own side of the file reads it.
    func tokens(of row: GitDiffRow, oldSide: Bool) -> [SyntaxToken]? {
        guard let index = row.lineIndex else { return nil }
        let side = oldSide ? highlights.old : highlights.new
        return index < side.count ? side[index] : nil
    }
}

// MARK: - List

/// Stacked (one column) or split (old | new) rows.
enum SurfaceDiffLayout: Sendable {
    case unified
    case split
}

/// A strip before a block of shown lines: the unmodified lines folded away above it (a click
/// shows them), or the block's `@@` range when nothing above is hidden; then the enclosing
/// declaration git would name.
struct SurfaceDiffFold: Equatable, Sendable {
    /// The first hidden line's old line number: stable across both layouts.
    var id: Int
    /// The hidden layout rows; empty for a range strip.
    var rows: Range<Int>
    /// `@@ -a,b +c,d @@`, shown when no lines are hidden.
    var range: String?
    var section: String

    var hiddenLines: Int { rows.count }
}

enum SurfaceDiffListRow: Equatable, Sendable {
    case header
    case fold(SurfaceDiffFold)
    /// A stacked row (index into `unified.rows`).
    case line(Int)
    /// A split row (index into `old.rows` and `new.rows`).
    case pair(Int)
    case end
}

/// The rows the diff list shows: the file header, then the changes with three lines of
/// context around each (git's default hunks), longer unmodified runs folded.
struct SurfaceDiffList: Equatable, Sendable {
    /// Context lines kept around each change.
    static let context = 3

    var rows: [SurfaceDiffListRow] = []
    /// The list row of each change's first line, in order.
    var changeRows: [Int] = []

    static let empty = SurfaceDiffList()

    static func build(
        _ document: SurfaceDiffDocument,
        layout: SurfaceDiffLayout,
        collapsed: Bool,
        expanded: Set<Int>
    ) -> SurfaceDiffList {
        var list = SurfaceDiffList(rows: [.header])
        guard !collapsed else { return list }
        let layoutRows = layout == .unified ? document.unified.rows : document.old.rows
        let changeStarts = Set(layout == .unified ? document.unified.changeStarts : document.old.changeStarts)
        func row(_ index: Int) -> SurfaceDiffListRow { layout == .unified ? .line(index) : .pair(index) }
        func isContext(_ index: Int) -> Bool { layoutRows[index].kind == .context }

        // Hidden runs of context rows.
        var hidden: [Range<Int>] = []
        var index = 0
        while index < layoutRows.count {
            guard isContext(index) else {
                index += 1
                continue
            }
            let start = index
            while index < layoutRows.count, isContext(index) { index += 1 }
            let atStart = start == 0
            let atEnd = index == layoutRows.count
            let from = atStart ? start : start + context
            let to = atEnd ? index : index - context
            if to > from {
                let fold = from..<to
                let id = oldNumber(document, layoutRows[fold.lowerBound]) ?? fold.lowerBound
                if !expanded.contains(id) { hidden.append(fold) }
            }
        }

        var next = 0
        var hiddenIndex = 0
        var blockStarted = false
        while next < layoutRows.count {
            if hiddenIndex < hidden.count, hidden[hiddenIndex].lowerBound == next {
                let fold = hidden[hiddenIndex]
                hiddenIndex += 1
                let id = oldNumber(document, layoutRows[fold.lowerBound]) ?? fold.lowerBound
                list.rows.append(.fold(SurfaceDiffFold(
                    id: id,
                    rows: fold,
                    range: nil,
                    section: fold.upperBound < layoutRows.count ? section(document, before: layoutRows[fold.upperBound]) : ""
                )))
                next = fold.upperBound
                blockStarted = true
                continue
            }
            if !blockStarted {
                // The file opens with a change: its block's range, as git heads a hunk.
                let blockEnd = hiddenIndex < hidden.count ? hidden[hiddenIndex].lowerBound : layoutRows.count
                list.rows.append(.fold(SurfaceDiffFold(
                    id: -1,
                    rows: next..<next,
                    range: rangeText(document, rows: Array(layoutRows[next..<blockEnd]), layout: layout,
                                     newRows: layout == .split ? Array(document.new.rows[next..<blockEnd]) : []),
                    section: ""
                )))
                blockStarted = true
            }
            if changeStarts.contains(next) { list.changeRows.append(list.rows.count) }
            list.rows.append(row(next))
            next += 1
        }
        list.rows.append(.end)
        return list
    }

    private static func oldNumber(_ document: SurfaceDiffDocument, _ row: GitDiffRow) -> Int? {
        row.lineIndex.flatMap { document.lines[$0].oldNumber }
    }

    /// Git's default function context: the nearest line of the old file above `row` that
    /// starts with a letter, `_` or `$`, at most 80 characters.
    static func section(_ document: SurfaceDiffDocument, before row: GitDiffRow) -> String {
        guard var index = row.lineIndex else { return "" }
        while index > 0 {
            index -= 1
            let line = document.lines[index]
            guard line.kind != .added, let first = line.text.unicodeScalars.first else { continue }
            if CharacterSet.letters.contains(first) || first == "_" || first == "$" {
                let trimmed = line.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                return String(trimmed.prefix(80))
            }
        }
        return ""
    }

    /// `@@ -a,b +c,d @@` for a block of shown rows.
    private static func rangeText(
        _ document: SurfaceDiffDocument,
        rows: [GitDiffRow],
        layout: SurfaceDiffLayout,
        newRows: [GitDiffRow]
    ) -> String {
        let indices = (rows + newRows).compactMap(\.lineIndex)
        let lines = Set(indices).sorted().map { document.lines[$0] }
        let oldNumbers = lines.compactMap(\.oldNumber)
        let newNumbers = lines.compactMap(\.newNumber)
        return "@@ -\(oldNumbers.first ?? 0),\(oldNumbers.count) +\(newNumbers.first ?? 0),\(newNumbers.count) @@"
    }
}

// MARK: - Selection

/// Whole lines selected in the diff list: the list rows from `anchor` (where
/// the drag or click started) to `head`, on the side the drag started on in
/// split view (`oldSide`; stacked rows have one side).
struct SurfaceDiffSelection: Equatable, Sendable {
    var anchor: Int
    var head: Int
    var oldSide: Bool

    var rows: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
}

extension SurfaceDiffList {
    /// The file line a list row shows on one side: a stacked row's line, or a
    /// split row's old or new line; nil for headers, folds and fillers.
    func line(atRow row: Int, oldSide: Bool, in document: SurfaceDiffDocument) -> GitDiffLine? {
        guard rows.indices.contains(row) else { return nil }
        let layoutRow: GitDiffRow
        switch rows[row] {
        case .line(let index): layoutRow = document.unified.rows[index]
        case .pair(let index): layoutRow = oldSide ? document.old.rows[index] : document.new.rows[index]
        case .header, .fold, .end: return nil
        }
        return layoutRow.lineIndex.map { document.lines[$0] }
    }

    /// The text ⌘C copies: the selected lines as the file has them, one per
    /// line, without markers or line numbers.
    func text(of selection: SurfaceDiffSelection, in document: SurfaceDiffDocument) -> String {
        selection.rows
            .compactMap { line(atRow: $0, oldSide: selection.oldSide, in: document)?.text }
            .joined(separator: "\n")
    }
}
