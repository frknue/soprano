import AppKit
import SopranoAgentsCore

/// Syntax colors for both sides of a diff, per line, so every row is colored
/// as the line reads in its own version of the file. Port of Soprano's
/// `GitDiffHighlights` (`Controllers/GitChanges.swift`), keyed by old and new
/// line number instead of by diff line index, because it is computed from a
/// whole-file diff and applied to the shown (short-context) one.
struct DiffHighlights: Equatable, Sendable {
    /// Larger sides stay uncolored, like large files in Soprano's editor.
    static let maximumLength = 1_500_000

    /// Tokens of each old (`old`) and new (`new`) file line, ranges relative
    /// to the line; lines without tokens are absent.
    var old: [Int: [SyntaxToken]] = [:]
    var new: [Int: [SyntaxToken]] = [:]

    static let none = DiffHighlights()

    var isEmpty: Bool { old.isEmpty && new.isEmpty }

    /// The language of one side's path (last path component); nil is plain text.
    static func language(of path: String?) -> CodeLanguage? {
        guard let path, let name = path.split(separator: "/").last else { return nil }
        return CodeLanguage.forFile(named: String(name))
    }

    /// Whether a loaded document gets colors at all: text hunks only, never
    /// conflicted (combined) diffs or diffs cut at the line limit, and at
    /// least one side in a known language.
    static func applies(to document: DiffDocument, isConflicted: Bool) -> Bool {
        guard let file = document.file, !file.isBinary, !file.hunks.isEmpty, !isConflicted, !document.isTruncated else {
            return false
        }
        return language(of: file.oldPath) != nil || language(of: file.newPath) != nil
    }

    /// Colors from a full-context diff of the file: each side rebuilt as a
    /// whole text (old = every line but the added ones, new = every line but
    /// the removed ones) and highlighted in that side's language.
    static func compute(file: FileDiff) -> DiffHighlights {
        guard !file.isBinary else { return .none }
        let lines = file.hunks.flatMap(\.lines)
        return DiffHighlights(
            old: side(of: lines, excluding: .added, number: \.oldNumber, language: language(of: file.oldPath)),
            new: side(of: lines, excluding: .removed, number: \.newNumber, language: language(of: file.newPath))
        )
    }

    /// Highlights one version of the file as a whole, so multi-line strings
    /// and comments color correctly, then splits the tokens per line
    /// (Soprano's `GitDiffHighlights.side`).
    private static func side(
        of lines: [DiffLine],
        excluding excluded: DiffLine.Kind,
        number: KeyPath<DiffLine, Int?>,
        language: CodeLanguage?
    ) -> [Int: [SyntaxToken]] {
        guard let language else { return [:] }
        var numbers: [Int] = []
        var starts: [Int] = []
        var lengths: [Int] = []
        var text = ""
        var length = 0
        for line in lines where line.kind != excluded && line.kind != .noNewlineMarker {
            guard let lineNumber = line[keyPath: number] else { continue }
            if !numbers.isEmpty {
                text += "\n"
                length += 1
            }
            let lineLength = line.text.utf16.count
            numbers.append(lineNumber)
            starts.append(length)
            lengths.append(lineLength)
            text += line.text
            length += lineLength
            if length > maximumLength {
                return [:]
            }
        }
        guard !numbers.isEmpty else { return [:] }

        var result: [Int: [SyntaxToken]] = [:]
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
                    result[numbers[line], default: []].append(SyntaxToken(
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
