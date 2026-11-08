import AppKit

// The diff drawing the chat's file rows share, ported from Soprano Agents' Diff panel
// (`GitModels`, `DiffParser`, `DiffHighlights`, `DiffRows`): unified hunks parsed into lines,
// colored per side of the file, drawn as stacked rows with tint, change bar and line number.

struct DiffLine: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
        /// "\ No newline at end of file", attached to the line before it.
        case noNewlineMarker
    }

    var kind: Kind
    /// Line text without the leading +/-/space.
    var text: String
    var oldNumber: Int?
    var newNumber: Int?

    static let noNewlineText = "No newline at end of file"
    /// Longest prefix of a line a row draws (minified files would otherwise stall layout).
    static let maximumDrawnLength = 2000

    /// Columns the line takes in a monospaced font: tabs four, CJK and emoji two.
    var columns: Int {
        if kind == .noNewlineMarker { return Self.noNewlineText.count }
        var columns = 0
        for character in text.prefix(Self.maximumDrawnLength) {
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
}

struct DiffHunk: Sendable, Hashable {
    var oldStart: Int
    var newStart: Int
    /// Text after the closing "@@" (a hashline op, the enclosing function), may be empty.
    var section: String
    var lines: [DiffLine]
}

/// Unified hunks (`@@ -a,b +c,d @@ section` and their `+`/`-`/` ` lines) as `DiffHunk`s; file
/// header lines before the first hunk are skipped.
enum DiffHunkParser {
    static func parse(_ text: String) -> [DiffHunk] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var hunks: [DiffHunk] = []
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0
        for raw in lines {
            if hunk != nil, oldRemaining > 0 || newRemaining > 0 || raw.first == "\\" {
                let body = String(raw.dropFirst())
                switch raw.first {
                case "+":
                    hunk?.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine))
                    newLine += 1
                    newRemaining -= 1
                    continue
                case "-":
                    hunk?.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                    oldRemaining -= 1
                    continue
                case " ", nil:
                    // An empty line is a context line whose space was stripped.
                    hunk?.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                    continue
                case "\\":
                    hunk?.lines.append(DiffLine(kind: .noNewlineMarker, text: String(raw), oldNumber: nil, newNumber: nil))
                    continue
                default:
                    break
                }
            }
            guard let header = Header(String(raw)) else { continue }
            if let finished = hunk { hunks.append(finished) }
            hunk = DiffHunk(oldStart: header.oldStart, newStart: header.newStart, section: header.section, lines: [])
            oldLine = header.oldStart
            newLine = header.newStart
            oldRemaining = header.oldCount
            newRemaining = header.newCount
        }
        if let finished = hunk { hunks.append(finished) }
        return hunks
    }

    /// "@@ -a[,b] +c[,d] @@ section".
    private struct Header {
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
}

/// Syntax colors for both sides of a diff, per line, so every row is colored as the line reads
/// in its own version of the file; keyed by old and new line number.
struct DiffHighlights: Equatable, Sendable {
    /// Larger sides stay uncolored.
    static let maximumLength = 1_500_000

    var old: [Int: [SyntaxToken]] = [:]
    var new: [Int: [SyntaxToken]] = [:]

    static let none = DiffHighlights()

    /// Colors from the hunks of `path`: each side rebuilt from its lines and highlighted whole,
    /// so multi-line strings and comments color correctly.
    static func compute(hunks: [DiffHunk], path: String) -> DiffHighlights {
        guard let name = path.split(separator: "/").last, let language = CodeLanguage.forFile(named: String(name)) else { return .none }
        let lines = hunks.flatMap(\.lines)
        return DiffHighlights(
            old: side(of: lines, excluding: .added, number: \.oldNumber, language: language),
            new: side(of: lines, excluding: .removed, number: \.newNumber, language: language)
        )
    }

    private static func side(
        of lines: [DiffLine],
        excluding excluded: DiffLine.Kind,
        number: KeyPath<DiffLine, Int?>,
        language: CodeLanguage
    ) -> [Int: [SyntaxToken]] {
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
            if length > maximumLength { return [:] }
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
                if starts[middle] <= token.range.location { low = middle + 1 } else { high = middle }
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

/// Fonts, metrics and colors every diff row draws with: SF Mono 13 on a 20 pt line, a line-number
/// column in SF Mono 12, a 3 pt change bar on the left edge, additions and deletions tinted.
/// Rebuilt when the palette changes so rows never build fonts per draw.
@MainActor
struct DiffStyle {
    let palette: Palette
    let font: NSFont
    let semiboldFont: NSFont
    let italicFont: NSFont
    let numberFont: NSFont
    let wrappingAttributes: [NSAttributedString.Key: Any]
    let mutedAttributes: [NSAttributedString.Key: Any]
    /// Advance of one character of the (monospaced) code font.
    let columnWidth: CGFloat
    /// Natural height of one text line; the rest of `lineHeight` is split above and below.
    let textLineHeight: CGFloat

    static let lineHeight: CGFloat = 20
    static let barWidth: CGFloat = 3
    static let numberPadding: CGFloat = 10
    /// Space between the line-number column and the code.
    static let codeInset: CGFloat = 12
    static let codeTrailing: CGFloat = 12

    init(palette: Palette) {
        self.palette = palette
        font = Typography.mono()
        semiboldFont = Typography.mono(weight: .semibold)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        numberFont = Typography.mono(Typography.smallSize)
        textLineHeight = ceil(font.ascender - font.descender + font.leading)
        let single = NSMutableParagraphStyle()
        single.lineBreakMode = .byClipping
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byCharWrapping
        wrapping.lineSpacing = Self.lineHeight - textLineHeight
        wrappingAttributes = [.font: font, .foregroundColor: palette.foreground, .paragraphStyle: wrapping]
        mutedAttributes = [.font: font, .foregroundColor: palette.mutedForeground, .paragraphStyle: single]
        columnWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
    }

    /// Width of a line-number column for numbers up to `maxLine`.
    func numberWidth(maxLine: Int) -> CGFloat {
        let digits = max(2, String(max(1, maxLine)).count)
        let digit = NSAttributedString(string: "0", attributes: [.font: numberFont]).size().width
        return ceil(CGFloat(digits) * digit) + Self.numberPadding * 2
    }

    /// Rows of text a line wraps to in `width` points.
    func wrappedLines(of line: DiffLine, width: CGFloat) -> Int {
        let columns = line.columns
        guard columns > 0 else { return 1 }
        let fitting = max(1, Int(floor(width / columnWidth)))
        return max(1, Int((Double(columns) / Double(fitting)).rounded(.up)))
    }

    func syntaxColor(_ kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword, .tag, .heading: palette.mergedForeground
        case .string: palette.infoForeground
        case .comment: palette.mutedForeground
        case .number, .attribute: palette.warningForeground
        case .type: palette.inputForeground
        case .function, .key: palette.foreground
        case .inserted: palette.diffAdditionForeground
        case .deleted: palette.diffDeletionForeground
        }
    }

    /// The line's text, colored by its syntax tokens, tabs as four spaces, wrapped.
    func text(of line: DiffLine, tokens: [SyntaxToken]?) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: DiffLine.noNewlineText, attributes: mutedAttributes)
        }
        let raw = line.text
        let cut = raw.count > DiffLine.maximumDrawnLength ? String(raw.prefix(DiffLine.maximumDrawnLength)) : raw
        let text = NSMutableAttributedString(string: cut, attributes: wrappingAttributes)
        let length = text.length
        for token in tokens ?? [] where token.range.location < length {
            let range = NSRange(location: token.range.location, length: min(token.range.length, length - token.range.location))
            text.addAttribute(.foregroundColor, value: syntaxColor(token.kind), range: range)
            if token.kind.isEmphasized {
                text.addAttribute(.font, value: semiboldFont, range: range)
            } else if token.kind.isItalic {
                text.addAttribute(.font, value: italicFont, range: range)
            }
        }
        if cut.contains("\t") {
            text.mutableString.replaceOccurrences(of: "\t", with: "    ", options: [], range: NSRange(location: 0, length: length))
        }
        return text
    }

    func tint(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: palette.diffAdditionBackground
        case .removed: palette.diffDeletionBackground
        case .context, .noNewlineMarker: nil
        }
    }

    func bar(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: palette.success
        case .removed: palette.error
        case .context, .noNewlineMarker: nil
        }
    }

    func numberAttributes(for kind: DiffLine.Kind) -> [NSAttributedString.Key: Any] {
        let color: NSColor = switch kind {
        case .added: palette.diffAdditionForeground
        case .removed: palette.diffDeletionForeground
        case .context, .noNewlineMarker: palette.mutedForeground.withAlphaComponent(0.75)
        }
        return [.font: numberFont, .foregroundColor: color]
    }
}

/// What a line row shows.
struct DiffLineSide {
    var kind: DiffLine.Kind
    var number: Int?
    var text: NSAttributedString
}

@MainActor
enum DiffLineDrawing {
    /// One line (`minX..<maxX`): tint, bar, line number, then the wrapped text.
    static func draw(_ side: DiffLineSide, from minX: CGFloat, to maxX: CGFloat, height: CGFloat, numberWidth: CGFloat, style: DiffStyle) {
        if let tint = style.tint(for: side.kind) {
            tint.setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
            // The number column carries the tint twice, as a tinted gutter.
            NSRect(x: minX, y: 0, width: numberWidth, height: height).fill(using: .sourceOver)
        }
        if let bar = style.bar(for: side.kind) {
            bar.setFill()
            NSRect(x: minX, y: 0, width: DiffStyle.barWidth, height: height).fill()
        }
        if let number = side.number {
            let label = NSAttributedString(string: String(number), attributes: style.numberAttributes(for: side.kind))
            let size = label.size()
            label.draw(at: NSPoint(
                x: minX + numberWidth - DiffStyle.numberPadding - size.width,
                y: floor((DiffStyle.lineHeight - size.height) / 2)
            ))
        }
        let textX = minX + numberWidth + DiffStyle.codeInset
        let textMaxX = maxX - DiffStyle.codeTrailing
        guard textMaxX - textX > 4 else { return }
        let top = floor((DiffStyle.lineHeight - style.textLineHeight) / 2)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: textX, y: 0, width: textMaxX - textX, height: height).clip()
        side.text.draw(with: NSRect(x: textX, y: top, width: textMaxX - textX, height: height - top), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// "+12 -3" in the diff colors, mono; a zero count muted when `muteZero`.
enum DiffStatText {
    static func make(additions: Int, deletions: Int, palette: Palette, size: CGFloat, muteZero: Bool = false) -> NSAttributedString {
        let font = Typography.mono(size)
        let text = NSMutableAttributedString()
        let addColor = muteZero && additions == 0 ? palette.mutedForeground : palette.diffAdditionForeground
        let delColor = muteZero && deletions == 0 ? palette.mutedForeground : palette.diffDeletionForeground
        text.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: addColor]))
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        text.append(NSAttributedString(string: "-\(deletions)", attributes: [.font: font, .foregroundColor: delColor]))
        return text
    }
}
