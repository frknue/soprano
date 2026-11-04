import AppKit

/// One find highlight inside a view: which searchable unit, which range, whether it is the
/// current match.
struct FindHighlight: Hashable {
    var unit: Int
    var range: NSRange
    var active: Bool
}

extension Palette {
    /// Find matches, from the amber warning token.
    var findMatchBackground: NSColor { warning.timelineAlpha(isDark ? 0.42 : 0.32) }
    var findActiveBackground: NSColor { warning.timelineAlpha(isDark ? 0.85 : 0.75) }
}

// MARK: - Measuring

/// TextKit 1 heights of attributed text at a width, with the same container setup the text views
/// use (no padding, no inset). Cached per string instance and width, while the string lives (the
/// cache does not keep a streamed message's every version alive).
@MainActor
enum TextMeasure {
    private static let storage = NSTextStorage()
    private static let layoutManager: NSLayoutManager = {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return manager
    }()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        return container
    }()

    private struct Entry {
        weak var text: NSAttributedString?
        var heights: [CGFloat: CGFloat]
    }

    private static var cache: [ObjectIdentifier: Entry] = [:]

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let key = ObjectIdentifier(text)
        if let entry = cache[key], entry.text === text, let height = entry.heights[width] { return height }
        _ = layoutManager
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        var height = ceil(layoutManager.usedRect(for: container).height)
        if text.string.hasSuffix("\n") || text.string.hasSuffix("\u{2028}") {
            height += ceil(layoutManager.extraLineFragmentRect.height)
        }
        if cache.count > 4000 { cache.removeAll() }
        var entry = cache[key].flatMap { $0.text === text ? $0 : nil } ?? Entry(text: text, heights: [:])
        entry.heights[width] = height
        cache[key] = entry
        return height
    }

    /// Single-line width of `text`.
    static func width(_ text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 1000), options: [.usesLineFragmentOrigin]).width)
    }
}

// MARK: - Text view

/// Draws inline-code chips and block-quote rules behind the glyphs, and find highlights.
final class MarkdownLayoutManager: NSLayoutManager {
    var chipColor: NSColor = .clear
    var quoteRuleColor: NSColor = .clear

    /// Selection and find highlights hug the glyphs instead of filling the whole (1.625) line:
    /// each rect is cut into one band per line fragment it covers, from that line's baseline
    /// (glyphs sit low in the line, and a selection rect can span several lines).
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // Called from the text view's drawing, on the main thread.
        let textView = firstTextView
        let origin = MainActor.assumeIsolated { textView?.textContainerOrigin } ?? .zero
        var bands: [(line: ClosedRange<CGFloat>, glyphs: ClosedRange<CGFloat>)] = []
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)) { fragment, _, _, lineGlyphs, _ in
            let lineChars = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let first = min(max(lineChars.location, charRange.location), storage.length - 1)
            guard let font = storage.attribute(.font, at: first, effectiveRange: nil) as? NSFont else { return }
            let baseline = origin.y + fragment.minY + self.location(forGlyphAt: lineGlyphs.location).y
            let top = origin.y + fragment.minY
            bands.append((top...(top + fragment.height), (baseline - font.ascender - 1)...(baseline - font.descender + 1)))
        }
        color.setFill()
        for index in 0..<rectCount {
            let rect = rectArray[index]
            for band in bands where min(band.line.upperBound, rect.maxY) - max(band.line.lowerBound, rect.minY) > 1 {
                let fill = NSRect(x: rect.minX, y: band.glyphs.lowerBound, width: rect.width, height: band.glyphs.upperBound - band.glyphs.lowerBound)
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.timelineQuoteRules, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let rules = value as? [CGFloat], NSIntersectionRange(range, characters).length > 0 else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var top = CGFloat.greatestFiniteMagnitude
                var bottom: CGFloat = 0
                enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                    top = min(top, used.minY)
                    bottom = max(bottom, used.maxY)
                }
                guard bottom > top else { return }
                quoteRuleColor.setFill()
                for x in rules {
                    NSRect(x: origin.x + x, y: origin.y + top, width: 2, height: bottom - top).fill()
                }
            }
            storage.enumerateAttribute(.timelineInlineCode, in: characters) { value, range, _ in
                guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                chipColor.setFill()
                let lastGlyph = NSMaxRange(glyphs) - 1
                enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, glyphs)
                    guard part.length > 0 else { return }
                    let bounds = self.boundingRect(forGlyphRange: part, in: container)
                    let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                    let pad = font.pointSize * 0.12
                    let trailingKern: CGFloat = NSMaxRange(part) - 1 == lastGlyph ? 4 : 0
                    let rect = NSRect(
                        x: origin.x + bounds.minX - 3,
                        y: origin.y + baseline - font.ascender - pad,
                        width: bounds.width - trailingKern + 6,
                        height: font.ascender - font.descender + pad * 2
                    )
                    NSBezierPath(roundedRect: rect, xRadius: Radius.sm, yRadius: Radius.sm).fill()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Read-only, selectable rendered text (no insets, no padding), links open in the browser unless
/// `linkHandler` takes them.
final class MarkdownTextView: NSTextView {
    let markdownLayoutManager = MarkdownLayoutManager()
    /// Link clicks go here first; true = handled, else a web or mail link opens in its default app
    /// (`opensExternally`) and any other does nothing.
    var linkHandler: ((URL) -> Bool)?

    /// The schemes a click hands to their default app: never `file:`, an app or a custom scheme.
    nonisolated static func opensExternally(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    init() {
        let storage = NSTextStorage()
        storage.addLayoutManager(markdownLayoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        markdownLayoutManager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ text: NSAttributedString) {
        guard textStorage?.isEqual(to: text) != true else { return }
        textStorage?.setAttributedString(text)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return }
        if linkHandler?(url) == true { return }
        guard Self.opensExternally(url) else { return }
        super.clicked(onLink: url, at: charIndex)
    }

    func setWidth(_ width: CGFloat, height: CGFloat) {
        textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        frame.size = NSSize(width: width, height: height)
    }

    func applyColors(_ palette: Palette, quoteColor: NSColor) {
        markdownLayoutManager.chipColor = palette.foreground.timelineAlpha(0.1)
        markdownLayoutManager.quoteRuleColor = quoteColor
        linkTextAttributes = [.foregroundColor: palette.infoForeground, .cursor: NSCursor.pointingHand]
        selectedTextAttributes = [.backgroundColor: palette.primary.timelineAlpha(palette.isDark ? 0.45 : 0.22)]
        needsDisplay = true
    }

    func applyFind(_ ranges: [(NSRange, Bool)], palette: Palette) {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        markdownLayoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for (range, active) in ranges where NSMaxRange(range) <= storage.length {
            markdownLayoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: active ? palette.findActiveBackground : palette.findMatchBackground,
                forCharacterRange: range
            )
        }
        needsDisplay = true
    }

    /// Rect of a character range in the view.
    func rect(for range: NSRange) -> NSRect? {
        guard let container = textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let glyphs = markdownLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return markdownLayoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    // Scrolling belongs to the timeline.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - Code block

/// A Markdown code block: rounded 8, `bg-secondary` (dark `input/32`), header with the
/// language in mono 11 and a Copy button, code in SF Mono 13 with syntax colors.
final class CodeBlockView: PaletteView {
    static let headerHeight: CGFloat = 30
    static let padding = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    private let languageLabel = NSTextField.label("", size: Typography.tinySize)
    private let copyButton = GhostIconButton(symbol: Icon.copy, size: 24, symbolSize: 12, toolTip: "Copy code")
    let textView = MarkdownTextView()
    private var code = ""
    private var highlighted = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        layer?.masksToBounds = true
        languageLabel.font = Typography.mono(Typography.tinySize)
        addSubview(languageLabel)
        addSubview(copyButton)
        addSubview(textView)
        copyButton.onClick = { [weak self] in self?.copyCode() }
        applyPalette(palette)
    }

    func configure(language: String?, code: String, highlighted: NSAttributedString) {
        self.code = code
        self.highlighted = highlighted
        languageLabel.stringValue = language ?? ""
        textView.setText(highlighted)
    }

    static func height(highlighted: NSAttributedString, width: CGFloat) -> CGFloat {
        headerHeight + padding.top + max(TextMeasure.height(highlighted, width: width - padding.left - padding.right), 18) + padding.bottom
    }

    func layoutBlock(width: CGFloat) -> CGFloat {
        let textWidth = width - Self.padding.left - Self.padding.right
        let textHeight = max(TextMeasure.height(highlighted, width: textWidth), 18)
        copyButton.frame = NSRect(x: width - 6 - 24, y: 6, width: 24, height: 24)
        languageLabel.frame = NSRect(x: 12, y: 6 + (24 - 16) / 2, width: max(0, width - 12 - 36), height: 16)
        textView.frame.origin = NSPoint(x: Self.padding.left, y: Self.headerHeight + Self.padding.top)
        textView.setWidth(textWidth, height: textHeight)
        let height = Self.headerHeight + Self.padding.top + textHeight + Self.padding.bottom
        frame.size = NSSize(width: width, height: height)
        return height
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyButton.setSymbol(Icon.check, size: 12)
        copyButton.restingTint = palette.primary
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setSymbol(Icon.copy, size: 12)
            self?.copyButton.restingTint = nil
        }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.timelineAlpha(0.32) : palette.secondary).cgColor
        layer?.borderWidth = palette.isDark ? 0 : 1
        layer?.borderColor = palette.border.timelineAlpha(0.7).cgColor
        languageLabel.textColor = palette.foreground.timelineAlpha(0.72)
        textView.applyColors(palette, quoteColor: .clear)
    }
}

// MARK: - Table

/// GFM table with row separators only (diagnostics-style), cells wrap.
final class MarkdownTableView: PaletteView {
    private var table = MarkdownTableRendering(alignments: [], header: [], rows: [])
    private var cellViews: [MarkdownTextView] = []
    private var separators: [NSView] = []
    var linkHandler: ((URL) -> Bool)? {
        didSet { cellViews.forEach { $0.linkHandler = linkHandler } }
    }

    static let cellPadding = NSSize(width: 12, height: 7)
    static let headerPadding: CGFloat = 9

    func configure(_ table: MarkdownTableRendering) {
        self.table = table
        let cells = table.header + table.rows.flatMap { $0 }
        while cellViews.count < cells.count {
            let view = MarkdownTextView()
            view.linkHandler = linkHandler
            cellViews.append(view)
            addSubview(view)
        }
        for (index, view) in cellViews.enumerated() {
            view.isHidden = index >= cells.count
            if index < cells.count { view.setText(cells[index]) }
        }
        let lines = table.rows.count + (table.header.isEmpty ? 0 : 1)
        while separators.count < lines {
            let line = NSView()
            line.wantsLayer = true
            separators.append(line)
            addSubview(line)
        }
        for (index, line) in separators.enumerated() { line.isHidden = index >= lines }
        applyPalette(palette)
    }

    /// Column widths that fill `width` (CSS auto layout, roughly): natural widths when they fit,
    /// else shrink toward each column's longest word.
    static func columnWidths(_ table: MarkdownTableRendering, width: CGFloat) -> [CGFloat] {
        let count = table.columnCount
        guard count > 0 else { return [] }
        var natural = [CGFloat](repeating: 0, count: count)
        var minimum = [CGFloat](repeating: 0, count: count)
        for row in [table.header] + table.rows {
            for (column, cell) in row.enumerated() where column < count {
                natural[column] = max(natural[column], TextMeasure.width(cell))
                for word in cell.string.split(whereSeparator: \.isWhitespace) {
                    let range = (cell.string as NSString).range(of: String(word))
                    if range.location != NSNotFound {
                        minimum[column] = max(minimum[column], TextMeasure.width(cell.attributedSubstring(from: range)))
                    }
                }
            }
        }
        let paddings = (0..<count).map { padding(column: $0, count: count) }
        let available = width - paddings.reduce(0, +)
        let naturalTotal = natural.reduce(0, +)
        let minimumTotal = minimum.reduce(0, +)
        var result: [CGFloat]
        if naturalTotal <= available {
            let extra = available - naturalTotal
            result = natural.map { $0 + (naturalTotal > 0 ? extra * $0 / naturalTotal : extra / CGFloat(count)) }
        } else if minimumTotal >= available {
            result = minimum.map { $0 * max(0, available) / max(minimumTotal, 1) }
        } else {
            let factor = (available - minimumTotal) / max(naturalTotal - minimumTotal, 1)
            result = zip(minimum, natural).map { $0 + ($1 - $0) * factor }
        }
        return zip(result, paddings).map { $0 + $1 }
    }

    private static func padding(column: Int, count: Int) -> CGFloat {
        (column == 0 ? 0 : cellPadding.width) + (column == count - 1 ? 0 : cellPadding.width)
    }

    static func height(_ table: MarkdownTableRendering, width: CGFloat) -> CGFloat {
        let widths = columnWidths(table, width: width)
        var total: CGFloat = 0
        if !table.header.isEmpty { total += rowHeight(table.header, widths: widths, vertical: headerPadding) + 1 }
        for row in table.rows { total += rowHeight(row, widths: widths, vertical: cellPadding.height) + 1 }
        return total
    }

    private static func rowHeight(_ cells: [NSAttributedString], widths: [CGFloat], vertical: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for (column, cell) in cells.enumerated() where column < widths.count {
            height = max(height, TextMeasure.height(cell, width: widths[column] - padding(column: column, count: widths.count)))
        }
        return max(height, 20) + vertical * 2
    }

    func layoutTable(width: CGFloat) -> CGFloat {
        let widths = Self.columnWidths(table, width: width)
        var y: CGFloat = 0
        var cellIndex = 0
        var lineIndex = 0
        let rows = (table.header.isEmpty ? [] : [table.header]) + table.rows
        for (rowIndex, row) in rows.enumerated() {
            let vertical = rowIndex == 0 && !table.header.isEmpty ? Self.headerPadding : Self.cellPadding.height
            let rowHeight = Self.rowHeight(row, widths: widths, vertical: vertical)
            var x: CGFloat = 0
            for (column, cell) in row.enumerated() {
                guard column < widths.count, cellIndex < cellViews.count else { continue }
                let leading: CGFloat = column == 0 ? 0 : Self.cellPadding.width
                let cellWidth = widths[column] - Self.padding(column: column, count: widths.count)
                let view = cellViews[cellIndex]
                view.frame.origin = NSPoint(x: x + leading, y: y + vertical)
                view.setWidth(max(1, cellWidth), height: TextMeasure.height(cell, width: max(1, cellWidth)))
                x += widths[column]
                cellIndex += 1
            }
            y += rowHeight
            if lineIndex < separators.count {
                separators[lineIndex].frame = NSRect(x: 0, y: y, width: width, height: 1)
                lineIndex += 1
            }
            y += 1
        }
        frame.size = NSSize(width: width, height: y)
        return y
    }

    /// Splits a range of the table's searchable text ("cell\ncell\n…") onto cell views.
    func applyFind(_ ranges: [(NSRange, Bool)], palette: Palette) {
        let cells = table.header + table.rows.flatMap { $0 }
        var offset = 0
        for (index, cell) in cells.enumerated() where index < cellViews.count {
            let length = cell.length
            let local = ranges.compactMap { range, active -> (NSRange, Bool)? in
                let intersection = NSIntersectionRange(range, NSRange(location: offset, length: length))
                guard intersection.length > 0 else { return nil }
                return (NSRange(location: intersection.location - offset, length: intersection.length), active)
            }
            cellViews[index].applyFind(local, palette: palette)
            offset += length + 1
        }
    }

    func rect(for range: NSRange) -> NSRect? {
        let cells = table.header + table.rows.flatMap { $0 }
        var offset = 0
        for (index, cell) in cells.enumerated() where index < cellViews.count {
            if range.location >= offset, range.location < offset + cell.length + 1 {
                let view = cellViews[index]
                let local = NSRange(location: range.location - offset, length: min(range.length, cell.length - (range.location - offset)))
                return view.rect(for: local).map { $0.offsetBy(dx: view.frame.minX, dy: view.frame.minY) }
            }
            offset += cell.length + 1
        }
        return nil
    }

    override func applyPalette(_ palette: Palette) {
        for line in separators { line.layer?.backgroundColor = palette.border.timelineAlpha(0.6).cgColor }
        for view in cellViews { view.applyColors(palette, quoteColor: .clear) }
    }
}

// MARK: - Rule

final class MarkdownRuleView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}

// MARK: - Image

/// An image block of a document: the image at its natural size, scaled down to the width,
/// rounded 8 (Soprano's reader); its alt text in muted italics until the image arrives or when
/// it can't be shown.
final class MarkdownImageView: PaletteView {
    static let placeholderHeight: CGFloat = 26

    private let imageView = NSImageView()
    private let altLabel = NSTextField.label(size: Typography.bodySize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        altLabel.font = NSFontManager.shared.convert(Typography.ui(Typography.bodySize), toHaveTrait: .italicFontMask)
        altLabel.lineBreakMode = .byTruncatingTail
        addSubview(imageView)
        addSubview(altLabel)
        applyPalette(palette)
    }

    func configure(source: String, alt: String, image: NSImage?) {
        imageView.image = image
        imageView.setAccessibilityLabel(alt.isEmpty ? source : alt)
        imageView.isHidden = image == nil
        altLabel.stringValue = alt.isEmpty ? source : alt
        altLabel.toolTip = source
        altLabel.isHidden = image != nil
        needsLayout = true
    }

    /// The image's natural size (points), scaled down to `width`; the alt line without an image.
    static func size(of image: NSImage?, width: CGFloat) -> NSSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return NSSize(width: max(0, width), height: placeholderHeight)
        }
        let fitted = min(max(0, width), image.size.width)
        return NSSize(width: fitted, height: (image.size.height * fitted / image.size.width).rounded())
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        altLabel.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: bounds.width, height: 18)
    }

    override func applyPalette(_ palette: Palette) {
        altLabel.textColor = palette.mutedForeground
    }
}

// MARK: - Markdown view

/// Lays out a `MarkdownRendering` top to bottom at a width. Height comes from `TextMeasure`,
/// so `MarkdownView.height(of:width:)` (sizing) and `layoutMarkdown(width:)` (display) agree.
final class MarkdownView: PaletteView {
    private(set) var rendering: MarkdownRendering?
    private var segmentViews: [NSView] = []
    private var quoteColor: NSColor = .clear
    /// Pictures of the rendering's image blocks by source; the owner loads them (lay out again
    /// after changing them).
    var images: [String: NSImage] = [:] {
        didSet { configureImages() }
    }
    /// Link clicks of the text and table cells; true = handled, else a web or mail link opens in
    /// its default app.
    var linkHandler: ((URL) -> Bool)? {
        didSet { applyLinkHandler() }
    }

    /// Shows `rendering`, reusing the segment views of the same kind at the same place, so a
    /// streamed update keeps the views (and the selection) of the text above its end.
    func apply(_ rendering: MarkdownRendering) {
        guard rendering !== self.rendering else { return }
        self.rendering = rendering
        let previous = segmentViews
        segmentViews = rendering.pieces.enumerated().map { index, piece -> NSView in
            let existing = index < previous.count ? previous[index] : nil
            switch piece.segment {
            case let .text(text):
                let view = existing as? MarkdownTextView ?? MarkdownTextView()
                // Other text, not more of the same: the old selection means nothing in it.
                let continues = text.string.hasPrefix(view.string)
                view.setText(text)
                if !continues { view.setSelectedRange(NSRange(location: 0, length: 0)) }
                return view
            case let .code(language, code, highlighted, _):
                let view = existing as? CodeBlockView ?? CodeBlockView(frame: .zero)
                view.configure(language: language, code: code, highlighted: highlighted)
                return view
            case let .table(table, _):
                let view = existing as? MarkdownTableView ?? MarkdownTableView(frame: .zero)
                view.configure(table)
                return view
            case .rule:
                return existing as? MarkdownRuleView ?? MarkdownRuleView(frame: .zero)
            case .image:
                return existing as? MarkdownImageView ?? MarkdownImageView(frame: .zero)
            }
        }
        for view in previous where !segmentViews.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in segmentViews where view.superview !== self { addSubview(view) }
        configureImages()
        applyLinkHandler()
        applyPalette(palette)
    }

    private func configureImages() {
        guard let rendering else { return }
        for (piece, view) in zip(rendering.pieces, segmentViews) {
            guard case let .image(source, alt, _) = piece.segment, let imageView = view as? MarkdownImageView else { continue }
            imageView.configure(source: source, alt: alt, image: images[source])
        }
    }

    private func applyLinkHandler() {
        for view in segmentViews {
            (view as? MarkdownTextView)?.linkHandler = linkHandler
            (view as? MarkdownTableView)?.linkHandler = linkHandler
        }
    }

    /// A point in the rendering that survives relayout: a segment and the distance into it.
    struct ReadingPosition {
        var segment: Int
        var offset: CGFloat
    }

    /// The segment at or below `y` (this view's coordinates) and `y`'s distance from its top
    /// (negative in the gap above it).
    func readingPosition(at y: CGFloat) -> ReadingPosition? {
        guard let last = segmentViews.indices.last else { return nil }
        let index = segmentViews.firstIndex { $0.frame.maxY > y } ?? last
        return ReadingPosition(segment: index, offset: y - segmentViews[index].frame.minY)
    }

    func y(of position: ReadingPosition) -> CGFloat? {
        guard position.segment < segmentViews.count else { return nil }
        return segmentViews[position.segment].frame.minY + position.offset
    }

    /// Top of the heading whose anchor (`.markdownAnchor`) is `slug`, in this view's coordinates.
    func anchorTop(_ slug: String) -> CGFloat? {
        guard let rendering else { return nil }
        for (index, piece) in rendering.pieces.enumerated() {
            guard case let .text(text) = piece.segment else { continue }
            var found: NSRange?
            text.enumerateAttribute(.markdownAnchor, in: NSRange(location: 0, length: text.length)) { value, range, stop in
                if value as? String == slug {
                    found = range
                    stop.pointee = true
                }
            }
            if let found, let rect = findRect(unit: index, range: found) { return rect.minY }
        }
        return nil
    }

    static func height(of rendering: MarkdownRendering, width: CGFloat, images: [String: NSImage] = [:]) -> CGFloat {
        var y: CGFloat = 0
        for piece in rendering.pieces {
            y += piece.spacingBefore + segmentHeight(piece.segment, width: width, images: images)
        }
        return ceil(y)
    }

    private static func segmentHeight(_ segment: MarkdownSegment, width: CGFloat, images: [String: NSImage]) -> CGFloat {
        switch segment {
        case let .text(text): TextMeasure.height(text, width: width)
        case let .code(_, _, highlighted, indent): CodeBlockView.height(highlighted: highlighted, width: width - indent)
        case let .table(table, indent): MarkdownTableView.height(table, width: width - indent)
        case .rule: 1
        case let .image(source, _, indent): MarkdownImageView.size(of: images[source], width: width - indent).height
        }
    }

    @discardableResult
    func layoutMarkdown(width: CGFloat) -> CGFloat {
        guard let rendering else { return 0 }
        var y: CGFloat = 0
        for (piece, view) in zip(rendering.pieces, segmentViews) {
            y += piece.spacingBefore
            switch piece.segment {
            case let .text(text):
                let height = TextMeasure.height(text, width: width)
                view.frame.origin = NSPoint(x: 0, y: y)
                (view as? MarkdownTextView)?.setWidth(width, height: height)
                y += height
            case let .code(_, _, _, indent):
                guard let block = view as? CodeBlockView else { continue }
                block.frame.origin = NSPoint(x: indent, y: y)
                y += block.layoutBlock(width: width - indent)
            case let .table(_, indent):
                guard let table = view as? MarkdownTableView else { continue }
                table.frame.origin = NSPoint(x: indent, y: y)
                y += table.layoutTable(width: width - indent)
            case let .rule(indent):
                view.frame = NSRect(x: indent, y: y, width: width - indent, height: 1)
                y += 1
            case let .image(source, _, indent):
                let size = MarkdownImageView.size(of: images[source], width: width - indent)
                view.frame = NSRect(origin: NSPoint(x: indent, y: y), size: size)
                y += size.height
            }
        }
        frame.size = NSSize(width: width, height: ceil(y))
        return ceil(y)
    }

    /// Highlights for the rendering's searchable units (one per segment).
    func applyFind(_ highlights: [FindHighlight]) {
        let palette = palette
        for (index, view) in segmentViews.enumerated() {
            let ranges = highlights.filter { $0.unit == index }.map { ($0.range, $0.active) }
            switch view {
            case let text as MarkdownTextView: text.applyFind(ranges, palette: palette)
            case let code as CodeBlockView: code.textView.applyFind(ranges, palette: palette)
            case let table as MarkdownTableView: table.applyFind(ranges, palette: palette)
            default: break
            }
        }
    }

    func findRect(unit: Int, range: NSRange) -> NSRect? {
        guard unit < segmentViews.count else { return nil }
        let view = segmentViews[unit]
        let local: NSRect? = switch view {
        case let text as MarkdownTextView: text.rect(for: range)
        case let code as CodeBlockView: code.textView.rect(for: range).map { $0.offsetBy(dx: code.textView.frame.minX, dy: code.textView.frame.minY) }
        case let table as MarkdownTableView: table.rect(for: range)
        default: nil
        }
        return local.map { $0.offsetBy(dx: view.frame.minX, dy: view.frame.minY) }
    }

    /// Text color of quote rules follows the prose (`currentColor 35%`).
    func setQuoteColor(_ color: NSColor) {
        quoteColor = color
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        for view in segmentViews {
            (view as? MarkdownTextView)?.applyColors(palette, quoteColor: quoteColor)
        }
    }
}
