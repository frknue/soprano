import AppKit

// MARK: - Rendered Diff

/// Line numbers shown in the gutter for one row.
struct DiffRowNumbers: Equatable, Sendable {
    var old: Int?
    var new: Int?
}

/// One text view's worth of a diff: the inline view, or one side of the
/// side-by-side view. Built off the main thread; only colors are applied
/// on it, so a theme change never re-reads git.
struct DiffRenderedSide: Sendable {
    enum Gutter: Sendable {
        /// Old and new numbers plus a +/− marker.
        case inline
        case old
        case new
    }

    /// A changed range within a row, in text offsets.
    struct Emphasis: Sendable {
        var range: NSRange
        var isAddition: Bool
    }

    let gutter: Gutter
    /// Every row's line text followed by a newline.
    let text: String
    let rows: [GitDiffRow]
    /// UTF-16 offset of each row in `text`.
    let rowStarts: [Int]
    let numbers: [DiffRowNumbers]
    /// A line index per row, for keeping the reading position when the
    /// view switches between inline and side by side.
    let anchors: [Int]
    /// Syntax tokens with ranges in `text`.
    let tokens: [SyntaxToken]
    let emphasis: [Emphasis]
    let changeStarts: [Int]
    /// The widest number the gutter shows.
    let largestNumber: Int

    init(
        layout: GitDiffLayout,
        gutter: Gutter,
        lines: [GitDiffLine],
        highlights: GitDiffHighlights,
        anchors: [Int]
    ) {
        var text = ""
        var rowStarts: [Int] = []
        var numbers: [DiffRowNumbers] = []
        var tokens: [SyntaxToken] = []
        var emphasis: [Emphasis] = []
        var largestNumber = 0
        var offset = 0
        rowStarts.reserveCapacity(layout.rows.count)
        numbers.reserveCapacity(layout.rows.count)

        for row in layout.rows {
            rowStarts.append(offset)
            guard let index = row.lineIndex else {
                numbers.append(DiffRowNumbers())
                text += "\n"
                offset += 1
                continue
            }
            let line = lines[index]
            let length = line.text.utf16.count
            // A removed line reads as the old file has it, every other line as the new one.
            let usesOld = gutter == .old || (gutter == .inline && row.kind == .removed)
            let sideTokens = usesOld ? highlights.old : highlights.new
            if index < sideTokens.count {
                for token in sideTokens[index] where NSMaxRange(token.range) <= length {
                    tokens.append(SyntaxToken(
                        range: NSRange(location: token.range.location + offset, length: token.range.length),
                        kind: token.kind
                    ))
                }
            }
            if let changed = row.changedRange, changed.length > 0, NSMaxRange(changed) <= length {
                emphasis.append(Emphasis(
                    range: NSRange(location: changed.location + offset, length: changed.length),
                    isAddition: row.kind == .added
                ))
            }
            numbers.append(DiffRowNumbers(old: line.oldNumber, new: line.newNumber))
            switch gutter {
            case .inline:
                largestNumber = max(largestNumber, line.oldNumber ?? 0, line.newNumber ?? 0)
            case .old:
                largestNumber = max(largestNumber, line.oldNumber ?? 0)
            case .new:
                largestNumber = max(largestNumber, line.newNumber ?? 0)
            }
            text += line.text
            text += "\n"
            offset += length + 1
        }

        self.gutter = gutter
        self.text = text
        self.rows = layout.rows
        self.rowStarts = rowStarts
        self.numbers = numbers
        self.anchors = anchors
        self.tokens = tokens
        self.emphasis = emphasis
        self.changeStarts = layout.changeStarts
        self.largestNumber = largestNumber
    }
}

/// Both layouts of one text diff, so switching between them needs no reload.
struct DiffRendering: Sendable {
    let lines: [GitDiffLine]
    let inline: DiffRenderedSide
    let old: DiffRenderedSide
    let new: DiffRenderedSide
    let linesAdded: Int
    let linesRemoved: Int

    init(lines: [GitDiffLine], language: CodeLanguage?) {
        let highlights = GitDiffHighlights.compute(lines, language: language)
        let inlineLayout = GitDiffLayout.inline(lines)
        let sides = GitDiffLayout.sideBySide(lines)
        // A side-by-side row stands for the earlier of the two lines it shows.
        let pairAnchors = zip(sides.old.rows, sides.new.rows).map { old, new in
            min(old.lineIndex ?? .max, new.lineIndex ?? .max)
        }
        self.lines = lines
        inline = DiffRenderedSide(
            layout: inlineLayout,
            gutter: .inline,
            lines: lines,
            highlights: highlights,
            anchors: inlineLayout.rows.map { $0.lineIndex ?? 0 }
        )
        old = DiffRenderedSide(layout: sides.old, gutter: .old, lines: lines, highlights: highlights, anchors: pairAnchors)
        new = DiffRenderedSide(layout: sides.new, gutter: .new, lines: lines, highlights: highlights, anchors: pairAnchors)
        var added = 0
        var removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: break
            }
        }
        linesAdded = added
        linesRemoved = removed
    }
}

// MARK: - Column

/// One scrolling text view of a diff with its gutter: the inline view, or
/// one side of the side-by-side view.
@MainActor
final class DiffColumn {
    let scrollView = NSScrollView()
    let textView: DiffTextView
    let ruler: DiffGutterRuler
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private(set) var side: DiffRenderedSide?
    private var colors: ThemeColors?

    init() {
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        textStorage.addLayoutManager(layoutManager)
        textView = DiffTextView(frame: .zero, textContainer: container)
        ruler = DiffGutterRuler(textView: textView)
        configure()
    }

    private func configure() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    /// Replaces the text; nil empties the column.
    func show(_ side: DiffRenderedSide?) {
        self.side = side
        textView.setRows(kinds: side?.rows.map(\.kind) ?? [], starts: side?.rowStarts ?? [])
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: side?.text ?? "")
        applyAttributes()
        textStorage.endEditing()
        ruler.show(side)
        // Brings the frame up to the new text before anything scrolls in it.
        textView.sizeToFit()
    }

    func apply(colors: ThemeColors) {
        self.colors = colors
        textView.colors = colors
        textView.backgroundColor = colors.bgBase
        textView.insertionPointColor = colors.accent
        textView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        scrollView.backgroundColor = colors.bgBase
        ruler.colors = colors
        textStorage.beginEditing()
        applyAttributes()
        textStorage.endEditing()
    }

    private func applyAttributes() {
        guard let colors else { return }
        let font = ChromeFont.monospaced(size: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        // A fixed row height keeps both sides aligned even where a fallback
        // font would make one line taller.
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colors.textPrimary,
            .paragraphStyle: paragraph,
        ]
        textView.typingAttributes = attributes
        let length = textStorage.length
        textStorage.setAttributes(attributes, range: NSRange(location: 0, length: length))
        guard let side else { return }
        for token in side.tokens where NSMaxRange(token.range) <= length {
            textStorage.addAttribute(
                .foregroundColor,
                value: EditorPaneView.color(for: token.kind, in: colors),
                range: token.range
            )
        }
        let addedEmphasis = colors.diffAddWord
        let removedEmphasis = colors.diffDeleteWord
        for emphasis in side.emphasis where NSMaxRange(emphasis.range) <= length {
            textStorage.addAttribute(
                .backgroundColor,
                value: emphasis.isAddition ? addedEmphasis : removedEmphasis,
                range: emphasis.range
            )
        }
    }

    // MARK: Scrolling

    var clipView: NSClipView { scrollView.contentView }

    /// The top of a row in text view coordinates.
    func rowTop(_ row: Int) -> CGFloat? {
        guard let side, row >= 0, row < side.rowStarts.count else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: side.rowStarts[row])
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minY + textView.textContainerOrigin.y
    }

    /// The row at a height in text view coordinates, clamped to the rows.
    func row(atY y: CGFloat) -> Int? {
        guard let side, !side.rowStarts.isEmpty, let container = textView.textContainer else { return nil }
        let point = NSPoint(x: 0, y: y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return textView.row(containing: character)
    }

    /// The row a third of the way down the visible area, where change
    /// navigation reads from and puts its target.
    func anchorRow() -> Int? {
        let bounds = clipView.bounds
        return row(atY: bounds.minY + bounds.height / 3)
    }

    /// Puts the row's top a third of the way down the visible area.
    func scroll(toRow row: Int) {
        guard let top = rowTop(row) else { return }
        let bounds = clipView.bounds
        scroll(to: NSPoint(x: bounds.minX, y: max(0, top - bounds.height / 3)))
    }

    /// The line index of the first visible row.
    func topAnchorLine() -> Int? {
        guard let side, let row = row(atY: clipView.bounds.minY), row < side.anchors.count else { return nil }
        return side.anchors[row]
    }

    /// Puts the last row at or before `line` at the top.
    func scroll(toAnchorLine line: Int) {
        guard let side, !side.anchors.isEmpty else { return }
        let row = side.anchors.lastIndex(where: { $0 <= line }) ?? 0
        guard let top = rowTop(row) else { return }
        scroll(to: NSPoint(x: clipView.bounds.minX, y: row == 0 ? 0 : top))
    }

    /// Scrolls the text to `point`, as far as the text reaches. The text lays
    /// out lazily and the text view only grows as it does, so a screenful
    /// past the target is laid out first; otherwise a jump far down the file
    /// would stop short.
    func scroll(to point: NSPoint) {
        let clip = clipView
        if let container = textView.textContainer {
            let origin = textView.textContainerOrigin
            layoutManager.ensureLayout(
                forBoundingRect: NSRect(x: 0, y: 0, width: textView.bounds.width, height: point.y - origin.y + clip.bounds.height),
                in: container
            )
        }
        let origin = clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Text View

/// A read-only diff text view painting each row's tint across its full width.
final class DiffTextView: NSTextView {
    var onFocus: (() -> Void)?
    /// F7 (true) and ⇧F7 (false): the next or previous change.
    var onNavigate: ((Bool) -> Void)?
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    private var rowKinds: [GitDiffRow.Kind] = []
    private var rowStarts: [Int] = []

    func setRows(kinds: [GitDiffRow.Kind], starts: [Int]) {
        rowKinds = kinds
        rowStarts = starts
        needsDisplay = true
    }

    /// The row holding a character: the last row starting at or before it.
    func row(containing characterIndex: Int) -> Int? {
        guard !rowStarts.isEmpty else { return nil }
        var low = 0
        var high = rowStarts.count
        while low < high {
            let middle = (low + high) / 2
            if rowStarts[middle] <= characterIndex {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                self?.onFocus?()
            }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .f7 {
            switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
            case []:
                onNavigate?(true)
                return
            case .shift:
                onNavigate?(false)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let colors, !rowStarts.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y),
            in: textContainer
        )
        guard glyphRange.length > 0 else { return }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, glyphs, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
            guard let row = self.row(containing: character) else { return }
            let kind = self.rowKinds[row]
            guard let tint = Self.tint(for: kind, colors: colors) else { return }
            let rowRect = NSRect(x: rect.minX, y: fragment.minY + origin.y, width: rect.width, height: fragment.height)
            tint.setFill()
            rowRect.fill(using: .sourceOver)
            if kind == .filler {
                Self.drawHatch(in: rowRect, color: colors.borderSubtle)
            }
        }
    }

    static func tint(for kind: GitDiffRow.Kind, colors: ThemeColors) -> NSColor? {
        switch kind {
        case .context: nil
        case .added: colors.diffAdd
        case .removed: colors.diffDelete
        case .filler: colors.diffFiller
        }
    }

    /// Thin diagonal lines, placed by absolute position so stacked filler
    /// rows join into one hatched block.
    private static func drawHatch(in rect: NSRect, color: NSColor) {
        let spacing: CGFloat = 8
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let path = NSBezierPath()
        path.lineWidth = 1
        var step = floor((rect.minX - rect.maxY) / spacing)
        let lastStep = ceil((rect.maxX - rect.minY) / spacing)
        while step <= lastStep {
            let offset = step * spacing
            path.move(to: NSPoint(x: offset + rect.minY, y: rect.minY))
            path.line(to: NSPoint(x: offset + rect.maxY, y: rect.maxY))
            step += 1
        }
        color.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Gutter

/// Line numbers beside each row, with the row's tint: old and new numbers
/// and a +/− marker inline, the side's own number side by side.
final class DiffGutterRuler: NSRulerView {
    private weak var diffTextView: DiffTextView?
    private var side: DiffRenderedSide?
    private var digits = 3
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    private let font = ChromeFont.monoSmall
    private let padding: CGFloat = 6

    init(textView: DiffTextView) {
        self.diffTextView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var digitWidth: CGFloat {
        ("8" as NSString).size(withAttributes: [.font: font]).width
    }

    private var isInline: Bool { side?.gutter == .inline }

    /// Right edges of the old and new number columns in the inline gutter.
    private var inlineColumns: (old: CGFloat, new: CGFloat, marker: CGFloat) {
        let width = CGFloat(digits) * digitWidth
        let old = padding + width
        let new = old + padding + width
        return (old, new, new + padding)
    }

    func show(_ side: DiffRenderedSide?) {
        self.side = side
        digits = max(3, String(side?.largestNumber ?? 0).count)
        let thickness = isInline
            ? ceil(inlineColumns.marker + digitWidth + padding + 1)
            : ceil(CGFloat(digits) * digitWidth + 18)
        if thickness != ruleThickness {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        // Views no longer clip to their bounds: a row scrolled half out of
        // view must not paint over the toolbar.
        NSBezierPath.clip(bounds)
        colors.bgPanel.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
        colors.borderSubtle.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let colors,
              let side,
              !side.rowStarts.isEmpty,
              let textView = diffTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard var row = textView.row(containing: characters.location) else { return }
        let end = NSMaxRange(characters)
        let columns = inlineColumns
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.textMuted]

        func drawLabel(_ label: String, rightEdge: CGFloat, in rowRect: NSRect, attributes: [NSAttributedString.Key: Any]) {
            let string = label as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: NSPoint(x: rightEdge - size.width, y: rowRect.minY + (rowRect.height - size.height) / 2),
                withAttributes: attributes
            )
        }

        while row < side.rowStarts.count, side.rowStarts[row] <= end {
            let glyph = layoutManager.glyphIndexForCharacter(at: side.rowStarts[row])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness - 1, height: fragment.height)
            let kind = side.rows[row].kind
            if let tint = DiffTextView.tint(for: kind, colors: colors) {
                tint.setFill()
                rowRect.fill(using: .sourceOver)
            }
            let numbers = side.numbers[row]
            switch side.gutter {
            case .inline:
                if let old = numbers.old {
                    drawLabel(String(old), rightEdge: columns.old, in: rowRect, attributes: numberAttributes)
                }
                if let new = numbers.new {
                    drawLabel(String(new), rightEdge: columns.new, in: rowRect, attributes: numberAttributes)
                }
                let marker: (String, NSColor)? = switch kind {
                case .added: ("+", colors.success)
                case .removed: ("−", colors.danger)
                case .context, .filler: nil
                }
                if let marker {
                    drawLabel(
                        marker.0,
                        rightEdge: columns.marker + digitWidth,
                        in: rowRect,
                        attributes: [.font: font, .foregroundColor: marker.1]
                    )
                }
            case .old:
                if let old = numbers.old {
                    drawLabel(String(old), rightEdge: ruleThickness - 9, in: rowRect, attributes: numberAttributes)
                }
            case .new:
                if let new = numbers.new {
                    drawLabel(String(new), rightEdge: ruleThickness - 9, in: rowRect, attributes: numberAttributes)
                }
            }
            row += 1
        }
    }
}
