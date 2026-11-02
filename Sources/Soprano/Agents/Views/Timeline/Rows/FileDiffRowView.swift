import AppKit
import SopranoAgentsCore

// MARK: - Parsed diff

/// A file change's diff ready to draw: hunk separators and lines, counts, syntax colors.
struct InlineDiff {
    enum Line {
        /// Between hunks ("⋯") or a hunk's section text (a hashline op: "PUT 12.=14:").
        case separator(String)
        /// `numbered`: the hunk states where it sits, so the line shows its number.
        case line(DiffLine, numbered: Bool)
    }

    var lines: [Line] = []
    var additions = 0
    var deletions = 0
    var highlights = DiffHighlights.none
    var maxNumber = 0

    /// Lines past this are not syntax colored (a streamed write recolors on every new line).
    static let highlightLimit = 3_000

    private var file: FileDiff?
    private var highlightable = false
    private(set) var isHighlighted = false

    /// `diff`: unified hunks as `FileChange.diff` carries them (a whole patch: the file at `path`).
    /// `fullContent`: the hunk is a written file's whole content, shown as plain lines.
    init(diff: String, path: String, fullContent: Bool = false) {
        let isPatch = diff.hasPrefix("diff ") || diff.hasPrefix("--- ")
        let header = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
        let files = DiffParser.parse(isPatch ? diff : header + diff)
        guard let file = files.first(where: { $0.newPath == path || $0.oldPath == path }) ?? files.first else { return }
        self.file = file
        var allNumbered = true
        for (index, hunk) in file.hunks.enumerated() {
            let numbered = hunk.oldStart != 0 || hunk.newStart != 0
            allNumbered = allNumbered && numbered
            if index > 0 || !hunk.section.isEmpty {
                lines.append(.separator(hunk.section.isEmpty ? "⋯" : hunk.section))
            }
            for var line in hunk.lines {
                switch line.kind {
                case .added: additions += 1
                case .removed: deletions += 1
                case .context, .noNewlineMarker: break
                }
                if fullContent, line.kind == .added { line.kind = .context }
                lines.append(.line(line, numbered: numbered))
                if numbered { maxNumber = max(maxNumber, line.oldNumber ?? 0, line.newNumber ?? 0) }
            }
        }
        // Unpositioned hunks share line numbers, so their tokens would collide.
        highlightable = allNumbered && lines.count <= Self.highlightLimit
    }

    /// Syntax colors, computed once the diff shows (a closed row only needs its counts).
    mutating func highlight() {
        guard !isHighlighted else { return }
        isHighlighted = true
        if highlightable, let file { highlights = DiffHighlights.compute(file: file) }
    }

    /// Per row id: the diff text it was parsed from and the result.
    @MainActor private static var cache: [String: (diff: String, fullContent: Bool, value: InlineDiff)] = [:]

    /// The diff of row `id`, parsed once per text (the sizing and the shown row both ask) and
    /// colored once `highlighted` (open).
    @MainActor
    static func of(_ change: FileChange, id: String, highlighted: Bool) -> InlineDiff? {
        guard let diff = change.diff, !diff.isEmpty else { return nil }
        let fullContent = change.isFullContent == true
        var value: InlineDiff
        if let cached = cache[id], cached.fullContent == fullContent, cached.diff == diff {
            guard highlighted, !cached.value.isHighlighted else { return cached.value }
            value = cached.value
        } else {
            value = InlineDiff(diff: diff, path: change.movePath ?? change.path, fullContent: fullContent)
        }
        if highlighted { value.highlight() }
        if cache[id] == nil, cache.count >= 512 { cache.removeAll() }
        cache[id] = (diff, fullContent, value)
        return value
    }
}

// MARK: - Diff lines

/// The lines of an inline diff, drawn like the Diff panel's stacked rows (tint, change bar,
/// line number, syntax colors), wrapped to the width. Only lines in the dirty rect draw.
final class InlineDiffView: NSView {
    private var diff = InlineDiff(diff: "", path: "")
    private var style = DiffStyle(palette: PaletteCenter.shared.palette)
    private var texts: [NSAttributedString?] = []
    private var offsets: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var numberWidth: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    func set(_ diff: InlineDiff, style: DiffStyle) {
        self.diff = diff
        self.style = style
        texts = Array(repeating: nil, count: diff.lines.count)
        laidOutWidth = -1
        needsDisplay = true
    }

    /// Lays the lines out for `width`; returns the document height.
    func layoutLines(width: CGFloat) -> CGFloat {
        if width != laidOutWidth || heights.count != diff.lines.count {
            laidOutWidth = width
            numberWidth = diff.maxNumber > 0 ? style.numberWidth(maxLine: diff.maxNumber) : DiffStyle.numberPadding
            let textWidth = max(1, width - numberWidth - DiffStyle.codeInset - DiffStyle.codeTrailing)
            heights = diff.lines.map { line in
                switch line {
                case .separator: DiffStyle.lineHeight
                case let .line(line, _): CGFloat(style.wrappedLines(of: line, width: textWidth)) * DiffStyle.lineHeight
                }
            }
            var y: CGFloat = 0
            offsets = heights.map { height in
                defer { y += height }
                return y
            }
        }
        return heights.reduce(0, +)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard heights.count == diff.lines.count else { return }
        let width = bounds.width
        for index in diff.lines.indices {
            let top = offsets[index]
            let height = heights[index]
            if top + height < dirtyRect.minY { continue }
            if top > dirtyRect.maxY { break }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: top)
            transform.concat()
            switch diff.lines[index] {
            case let .separator(text):
                style.palette.foreground.withAlphaComponent(style.palette.isDark ? 0.035 : 0.025).setFill()
                NSRect(x: 0, y: 0, width: width, height: height).fill(using: .sourceOver)
                let label = NSAttributedString(string: text, attributes: [
                    .font: style.numberFont,
                    .foregroundColor: style.palette.mutedForeground,
                ])
                let size = label.size()
                label.draw(with: NSRect(
                    x: numberWidth + DiffStyle.codeInset, y: floor((height - size.height) / 2),
                    width: max(0, width - numberWidth - DiffStyle.codeInset - DiffStyle.codeTrailing), height: size.height
                ), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            case let .line(line, numbered):
                let side = DiffLineSide(
                    kind: line.kind,
                    number: numbered ? (line.kind == .removed ? line.oldNumber : line.newNumber) : nil,
                    text: text(at: index, line: line)
                )
                DiffLineDrawing.draw(side, from: 0, to: width, height: height, numberWidth: numberWidth,
                                     wrap: true, offset: 0, style: style)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func text(at index: Int, line: DiffLine) -> NSAttributedString {
        if let text = texts[index] { return text }
        let tokens = switch line.kind {
        case .removed: line.oldNumber.flatMap { diff.highlights.old[$0] }
        case .added, .context: line.newNumber.flatMap { diff.highlights.new[$0] }
        case .noNewlineMarker: nil as [SyntaxToken]?
        }
        let text = style.text(of: line, tokens: tokens, emphasis: nil, wrap: true)
        texts[index] = text
        return text
    }
}

// MARK: - Row

/// One file an edit or write touched: "Edited Sources/App.swift  +12 −3" (shimmering while the
/// call runs) that opens to its diff, at most `bodyMaxHeight` tall (it scrolls). While the call
/// runs the diff keeps its newest line in view unless the user scrolled up.
final class FileDiffRowView: ClickableRowView {
    static let bodyMaxHeight: CGFloat = 360

    private let line = WorkLogLineView()
    private let bodyPanel = FlippedView()
    private let bodyScroll = PassThroughScrollView()
    private let diffView = InlineDiffView()
    private var model: FileDiffRowModel?
    private var diff: InlineDiff?
    private var style = DiffStyle(palette: PaletteCenter.shared.palette)
    /// The file the body last showed (a reused view starts at the top, or the end while live).
    private var shownID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(line)
        addSubview(bodyPanel)
        bodyPanel.wantsLayer = true
        bodyPanel.layer?.cornerRadius = Radius.md
        bodyPanel.layer?.masksToBounds = true
        bodyPanel.layer?.borderWidth = 1
        bodyPanel.addSubview(bodyScroll)
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.documentView = diffView
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .fileDiff(model) = row.content else { return }
        self.model = model
        diff = model.canExpand ? InlineDiff.of(model.change, id: model.id, highlighted: model.expanded) : nil
        line.icon.setSymbol(TimelineIcon.workEdit, size: 13)
        line.detail.stringValue = ""
        line.failMark.isHidden = model.status != .failed
        line.time.stringValue = TimelineFormat.timestamp(model.date)
        line.showsChevron = model.canExpand
        line.chevron.setSymbol(model.expanded ? Icon.chevronDown : Icon.chevronRight, size: 10, weight: .medium)
        line.label.isShimmering = model.isActive
        let open = model.expanded && diff != nil
        bodyPanel.isHidden = !open
        if open, let diff { diffView.set(diff, style: style) }
        setAccessibilityRole(model.canExpand ? .button : .row)
        setAccessibilityLabel(model.status == .failed ? "\(model.label), tool call failed" : model.label)
        onToggle = model.canExpand ? { [weak self] in
            guard let self, let model = self.model else { return }
            delegate?.timelineToggleDiff(model.id)
        } : nil
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        let pad: CGFloat = model.grouped ? 0 : 2
        line.showsTime = isHovered
        line.frame = NSRect(x: 0, y: pad, width: width, height: WorkLogLineView.height)
        line.layoutLine(width: width)
        var y = pad + WorkLogLineView.height
        headerRect = NSRect(x: 0, y: 0, width: width, height: y + pad)
        window?.invalidateCursorRects(for: self)
        if !bodyPanel.isHidden {
            y += 2
            let panelWidth = max(0, width - 30)
            let clip = bodyScroll.contentView
            let wasAtEnd = clip.bounds.maxY >= diffView.frame.height - 1
            let documentHeight = diffView.layoutLines(width: panelWidth)
            let shown = min(documentHeight, Self.bodyMaxHeight)
            bodyPanel.frame = NSRect(x: 30, y: y, width: panelWidth, height: shown + 8)
            bodyScroll.frame = NSRect(x: 0, y: 4, width: panelWidth, height: shown)
            diffView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: documentHeight)
            let isNewFile = shownID != model.id
            shownID = model.id
            if model.isActive, isNewFile || wasAtEnd {
                clip.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - shown)))
                bodyScroll.reflectScrolledClipView(clip)
            } else if isNewFile {
                clip.scroll(to: .zero)
                bodyScroll.reflectScrolledClipView(clip)
            }
            diffView.needsDisplay = true
            y += shown + 8 + 8
        }
        return y + pad
    }

    override func hoverChanged() {
        line.showsTime = isHovered
        line.layoutLine(width: bounds.width)
    }

    override func applyPalette(_ palette: Palette) {
        style = DiffStyle(palette: palette)
        if !bodyPanel.isHidden, let diff { diffView.set(diff, style: style) }
        bodyPanel.layer?.backgroundColor = palette.foreground.timelineAlpha(palette.isDark ? 0.04 : 0.03).cgColor
        bodyPanel.layer?.borderColor = palette.border.timelineAlpha(0.6).cgColor
        guard let model else { return }
        let labelColor = palette.secondaryLabel
        line.label.set(model.label, font: Typography.ui(Typography.bodySize), color: labelColor, highlightColor: palette.foreground)
        line.applyColors(palette: palette, labelColor: labelColor, failed: model.status == .failed)
        if let diff, model.change.isFullContent == true {
            // A write carries the whole new file, not a change: +N would claim every line is new.
            line.note.attributedStringValue = NSAttributedString(string: "\(diff.additions) \(diff.additions == 1 ? "line" : "lines")", attributes: [
                .font: Typography.mono(Typography.smallSize), .foregroundColor: palette.mutedForeground,
            ])
        } else if let diff, diff.additions + diff.deletions > 0 {
            line.note.attributedStringValue = DiffStatText.make(additions: diff.additions, deletions: diff.deletions, palette: palette, size: Typography.smallSize, muteZero: true)
        } else {
            line.note.stringValue = ""
        }
    }
}
