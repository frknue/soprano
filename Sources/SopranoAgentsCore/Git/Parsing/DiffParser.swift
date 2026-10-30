import Foundation

/// Parses unified diffs from `git diff` (one `FileDiff` per "diff --git").
/// Lines split on "\n" only, so a CRLF file's lines keep their "\r" and a
/// hunk rebuilds byte-exact; text decodes as UTF-8, lossily.
enum DiffParser {
    static func parse(_ data: Data) -> [FileDiff] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }

        var files: [FileDiff] = []
        var current: FileBuilder?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0

        func closeHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let builder = current { files.append(builder.build()) }
            current = nil
        }

        for raw in lines {
            let line = String(decoding: raw, as: UTF8.self)
            if hunk != nil {
                if oldRemaining > 0 || newRemaining > 0 {
                    let marker = raw.first
                    let text = String(decoding: raw.dropFirst(), as: UTF8.self)
                    switch marker {
                    case UInt8(ascii: "+"):
                        hunk?.lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: newLine))
                        newLine += 1
                        newRemaining -= 1
                        continue
                    case UInt8(ascii: "-"):
                        hunk?.lines.append(DiffLine(kind: .removed, text: text, oldNumber: oldLine, newNumber: nil))
                        oldLine += 1
                        oldRemaining -= 1
                        continue
                    case UInt8(ascii: " "), nil:
                        // An empty line is a context line whose space was stripped.
                        hunk?.lines.append(DiffLine(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                        oldLine += 1
                        newLine += 1
                        oldRemaining -= 1
                        newRemaining -= 1
                        continue
                    case UInt8(ascii: "\\"):
                        hunk?.lines.append(DiffLine(kind: .noNewlineMarker, text: line, oldNumber: nil, newNumber: nil))
                        continue
                    default:
                        break
                    }
                } else if raw.first == UInt8(ascii: "\\") {
                    hunk?.lines.append(DiffLine(kind: .noNewlineMarker, text: line, oldNumber: nil, newNumber: nil))
                    continue
                }
                closeHunk()
            }

            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                closeFile()
                current = FileBuilder(firstLine: line)
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("@@"), let header = HunkHeader(line) {
                closeHunk()
                hunk = DiffHunk(
                    oldStart: header.oldStart, oldCount: header.oldCount,
                    newStart: header.newStart, newCount: header.newCount,
                    section: header.section, lines: []
                )
                oldLine = header.oldStart
                newLine = header.newStart
                oldRemaining = header.oldCount
                newRemaining = header.newCount
                continue
            }
            if current?.hunks.isEmpty == true {
                current?.addHeader(line)
            }
        }
        closeFile()
        return files
    }

    /// "@@ -a[,b] +c[,d] @@ section".
    struct HunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var section: String

        init?(_ line: String) {
            guard line.hasPrefix("@@ -"),
                  let close = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex)
            else { return nil }
            let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
                  let old = Self.range(ranges[0].dropFirst()), let new = Self.range(ranges[1].dropFirst())
            else { return nil }
            (oldStart, oldCount) = old
            (newStart, newCount) = new
            var section = line[close.upperBound...]
            if section.first == " " { section = section.dropFirst() }
            self.section = String(section)
        }

        private static func range(_ text: Substring) -> (Int, Int)? {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            if parts.count == 1 { return (start, 1) }
            guard parts.count == 2, let count = Int(parts[1]) else { return nil }
            return (start, count)
        }
    }

    /// Collects one file's header lines into a `FileDiff`.
    private struct FileBuilder {
        var headerLines: [String]
        var oldPath: String?
        var newPath: String?
        var kind: ChangeKind = .modified
        var isBinary = false
        var oldMode: String?
        var newMode: String?
        var sawOldFileLine = false
        var sawNewFileLine = false
        var hunks: [DiffHunk] = []

        init(firstLine: String) {
            headerLines = [firstLine]
            if let (old, new) = Self.paths(fromDiffGit: firstLine) {
                oldPath = old
                newPath = new
            }
        }

        mutating func addHeader(_ line: String) {
            headerLines.append(line)
            if let mode = value(line, "new file mode ") {
                kind = .added
                newMode = mode
            } else if let mode = value(line, "deleted file mode ") {
                kind = .deleted
                oldMode = mode
            } else if let mode = value(line, "old mode ") {
                oldMode = mode
            } else if let mode = value(line, "new mode ") {
                newMode = mode
            } else if let path = value(line, "rename from ") {
                kind = .renamed
                oldPath = GitOutput.unquote(Substring(path))
            } else if let path = value(line, "rename to ") {
                kind = .renamed
                newPath = GitOutput.unquote(Substring(path))
            } else if let path = value(line, "copy from ") {
                kind = .copied
                oldPath = GitOutput.unquote(Substring(path))
            } else if let path = value(line, "copy to ") {
                kind = .copied
                newPath = GitOutput.unquote(Substring(path))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
            } else if let path = value(line, "--- ") {
                sawOldFileLine = true
                oldPath = Self.filePath(path, prefix: "a/")
            } else if let path = value(line, "+++ ") {
                sawNewFileLine = true
                newPath = Self.filePath(path, prefix: "b/")
            } else if line.hasPrefix("index "), oldMode == nil, newMode == nil,
                      let mode = line.split(separator: " ").dropFirst(2).first {
                // "index abc..def 100644": the mode both sides share.
                oldMode = String(mode)
                newMode = String(mode)
            }
        }

        func build() -> FileDiff {
            var oldPath = oldPath
            var newPath = newPath
            if kind == .added { oldPath = nil }
            if kind == .deleted { newPath = nil }
            return FileDiff(
                oldPath: oldPath, newPath: newPath, kind: kind, isBinary: isBinary,
                oldMode: oldMode, newMode: newMode, headerLines: headerLines, hunks: hunks
            )
        }

        private func value(_ line: String, _ prefix: String) -> String? {
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }

        /// "--- a/path" / "+++ b/path" (git appends a tab to names with spaces),
        /// nil for /dev/null.
        private static func filePath(_ text: String, prefix: String) -> String? {
            var text = Substring(text)
            if text.hasSuffix("\t") { text = text.dropLast() }
            let path = GitOutput.unquote(text)
            if path == "/dev/null" { return nil }
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }

        /// Paths from "diff --git a/X b/Y" for headers without ---/+++ lines
        /// (binary files, pure renames, mode changes). Unquoted names are
        /// split assuming X == Y, which holds whenever no rename header follows.
        static func paths(fromDiffGit line: String) -> (String, String)? {
            let rest = line.hasPrefix("diff --git ") ? Substring(line.dropFirst("diff --git ".count)) : nil
            guard let rest else {
                // Combined diffs: "diff --cc path".
                let path = line.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init)
                return path.map { ($0, $0) }
            }
            if rest.hasPrefix("\"") {
                guard let end = closingQuote(in: rest) else { return nil }
                let old = GitOutput.unquote(rest[...end])
                let newPart = rest[rest.index(after: end)...].drop(while: { $0 == " " })
                let new = GitOutput.unquote(newPart)
                return (strip(old, "a/"), strip(new, "b/"))
            }
            if rest.hasSuffix("\""), let start = rest.range(of: " \"", options: .backwards) {
                let old = String(rest[..<start.lowerBound])
                let new = GitOutput.unquote(rest[rest.index(after: start.lowerBound)...])
                return (strip(old, "a/"), strip(new, "b/"))
            }
            // "a/<p> b/<p>": both halves have the same length.
            let bytes = Array(rest.utf8)
            guard bytes.count >= 5, (bytes.count - 1) % 2 == 0 else { return nil }
            let half = (bytes.count - 1) / 2
            let old = String(decoding: bytes[..<half], as: UTF8.self)
            let new = String(decoding: bytes[(half + 1)...], as: UTF8.self)
            return (strip(old, "a/"), strip(new, "b/"))
        }

        private static func closingQuote(in text: Substring) -> Substring.Index? {
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                if text[index] == "\\" {
                    index = text.index(after: index)
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                if text[index] == "\"" { return index }
                index = text.index(after: index)
            }
            return nil
        }

        private static func strip(_ path: String, _ prefix: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
    }
}
