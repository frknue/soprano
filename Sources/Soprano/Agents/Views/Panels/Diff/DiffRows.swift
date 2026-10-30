import AppKit
import SopranoAgentsCore

/// Fonts, metrics and colors every diff row draws with (T3 Code's `@pierre/diffs` look): SF Mono
/// 13 on a 20 pt line, one line-number column per side in SF Mono 12, a 3 pt change bar on the
/// left edge, additions and deletions tinted, changed words on a stronger tint. Rebuilt when
/// the palette changes so rows never build fonts per draw.
@MainActor
struct DiffStyle {
    let palette: Palette
    let font: NSFont
    let semiboldFont: NSFont
    let italicFont: NSFont
    let numberFont: NSFont
    let textAttributes: [NSAttributedString.Key: Any]
    let wrappingAttributes: [NSAttributedString.Key: Any]
    let mutedAttributes: [NSAttributedString.Key: Any]
    /// Advance of one character of the (monospaced) code font.
    let columnWidth: CGFloat
    /// Natural height of one text line; the rest of `lineHeight` is split above and below.
    let textLineHeight: CGFloat

    static let lineHeight: CGFloat = 20
    static let headerHeight: CGFloat = 36
    static let hunkHeight: CGFloat = 28
    static let noticeHeight: CGFloat = 32
    static let fileEndHeight: CGFloat = 8
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
        textAttributes = [.font: font, .foregroundColor: palette.foreground, .paragraphStyle: single]
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

    /// Code characters that fit in `width` points (at least one).
    func columns(fitting width: CGFloat) -> Int {
        max(1, Int(floor(width / columnWidth)))
    }

    /// Rows of text a line wraps to in `width` points.
    func wrappedLines(of line: DiffLine, width: CGFloat) -> Int {
        let columns = DiffDocument.columns(of: line)
        guard columns > 0 else { return 1 }
        return max(1, Int((Double(columns) / Double(self.columns(fitting: width))).rounded(.up)))
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

    /// The line's text, colored by its syntax tokens, with the changed words of a paired line
    /// (`emphasis`, a UTF-16 range of the raw text) on the word tint; tabs as four spaces.
    func text(of line: DiffLine, tokens: [SyntaxToken]?, emphasis: NSRange?, wrap: Bool) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: DiffDocument.noNewlineText, attributes: mutedAttributes)
        }
        let raw = line.text
        let cut = raw.count > DiffDocument.maximumDrawnLength ? String(raw.prefix(DiffDocument.maximumDrawnLength)) : raw
        let text = NSMutableAttributedString(string: cut, attributes: wrap ? wrappingAttributes : textAttributes)
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
        if let emphasis, emphasis.location < length {
            let range = NSRange(location: emphasis.location, length: min(emphasis.length, length - emphasis.location))
            let color = line.kind == .added ? palette.diffAdditionWord : palette.diffDeletionWord
            text.addAttribute(.backgroundColor, value: color, range: range)
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

/// What one side of a line row shows.
struct DiffLineSide {
    var kind: DiffLine.Kind
    var number: Int?
    var text: NSAttributedString
}

/// Drawing shared by the stacked and split line rows.
@MainActor
enum DiffLineDrawing {
    /// One side (`minX..<maxX`) of a row: tint, bar, line number, then the text (wrapped, or on
    /// one line scrolled left by `offset`).
    static func draw(_ side: DiffLineSide?, from minX: CGFloat, to maxX: CGFloat, height: CGFloat,
                     numberWidth: CGFloat, wrap: Bool, offset: CGFloat, style: DiffStyle) {
        guard let side else {
            style.palette.foreground.withAlphaComponent(style.palette.isDark ? 0.035 : 0.025).setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
            return
        }
        if let tint = style.tint(for: side.kind) {
            tint.setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
            // The number column carries the tint twice, like pierre's gutter.
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
        if wrap {
            side.text.draw(
                with: NSRect(x: textX, y: top, width: textMaxX - textX, height: height - top),
                options: [.usesLineFragmentOrigin]
            )
        } else {
            side.text.draw(
                with: NSRect(x: textX - offset, y: top, width: 1_000_000, height: style.textLineHeight),
                options: [.usesLineFragmentOrigin]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A stacked diff line: one number column (old for deletions, new otherwise), then the code.
final class DiffUnifiedLineView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffUnifiedLine")

    private var side: DiffLineSide?
    private var style: DiffStyle?
    private var numberWidth: CGFloat = 0
    private var wrap = false
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset, !wrap { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(side: DiffLineSide, numberWidth: CGFloat, wrap: Bool, textOffset: CGFloat, style: DiffStyle) {
        self.side = side
        self.style = style
        self.numberWidth = numberWidth
        self.wrap = wrap
        self.textOffset = textOffset
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        DiffLineDrawing.draw(side, from: 0, to: bounds.width, height: bounds.height, numberWidth: numberWidth,
                             wrap: wrap, offset: textOffset, style: style)
    }
}

/// A split diff row: the old line left, the new line right, divided by a `border` hairline; a
/// missing side is a muted filler.
final class DiffSplitLineView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffSplitLine")

    private var old: DiffLineSide?
    private var new: DiffLineSide?
    private var style: DiffStyle?
    private var numberWidth: CGFloat = 0
    private var wrap = false
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset, !wrap { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func dividerX(rowWidth: CGFloat) -> CGFloat { floor(rowWidth / 2) }

    func configure(old: DiffLineSide?, new: DiffLineSide?, numberWidth: CGFloat, wrap: Bool, textOffset: CGFloat, style: DiffStyle) {
        self.old = old
        self.new = new
        self.style = style
        self.numberWidth = numberWidth
        self.wrap = wrap
        self.textOffset = textOffset
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let divider = Self.dividerX(rowWidth: bounds.width)
        DiffLineDrawing.draw(old, from: 0, to: divider, height: bounds.height, numberWidth: numberWidth,
                             wrap: wrap, offset: textOffset, style: style)
        DiffLineDrawing.draw(new, from: divider + 1, to: bounds.width, height: bounds.height, numberWidth: numberWidth,
                             wrap: wrap, offset: textOffset, style: style)
        style.palette.border.setFill()
        NSRect(x: divider, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// The separator before a hunk: "N unmodified lines" (or the `@@` range of a hunk that starts
/// the file) and the enclosing declaration, on a muted strip.
final class DiffHunkView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffHunk")

    private var text = NSAttributedString()
    private var style: DiffStyle?
    private var textX: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(hunk: DiffHunk, hiddenLines: Int, numberWidth: CGFloat, style: DiffStyle) {
        self.style = style
        textX = numberWidth + DiffStyle.codeInset
        let palette = style.palette
        let label = NSMutableAttributedString()
        let small = Typography.mono(Typography.smallSize)
        let lead = hiddenLines > 0
            ? "\(hiddenLines) unmodified \(hiddenLines == 1 ? "line" : "lines")"
            : "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        label.append(NSAttributedString(string: lead, attributes: [.font: small, .foregroundColor: palette.mutedForeground]))
        let section = hunk.section.trimmingCharacters(in: .whitespaces)
        if !section.isEmpty {
            label.append(NSAttributedString(string: "   " + section, attributes: [
                .font: small, .foregroundColor: palette.mutedForeground.withAlphaComponent(0.8),
            ]))
        }
        text = label
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let palette = style.palette
        palette.foreground.withAlphaComponent(palette.isDark ? 0.04 : 0.03).setFill()
        bounds.fill(using: .sourceOver)
        palette.border.fading(0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill(using: .sourceOver)
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
        if let image = NSImage.symbol("chevron.up.chevron.down", size: 10, weight: .medium) {
            let tinted = image.tinted(palette.mutedForeground)
            let size = tinted.size
            tinted.draw(in: NSRect(x: floor((textX - DiffStyle.codeInset - size.width) / 2), y: floor((bounds.height - size.height) / 2),
                                   width: size.width, height: size.height))
        }
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - DiffStyle.codeTrailing), height: bounds.height).clip()
        text.draw(at: NSPoint(x: textX, y: floor((bounds.height - size.height) / 2)))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A muted one-line note inside a file (binary file, rename only, truncation).
final class DiffNoticeView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffNotice")

    private let label = NSTextField.label(size: Typography.smallSize)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, palette: Palette) {
        label.stringValue = text
        label.textColor = palette.mutedForeground
    }
}

/// Space after a file's last row.
final class DiffFileEndView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffFileEnd")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A file's sticky header: collapse chevron, change glyph, path (directory muted, name in
/// foreground; "old → new" for renames), copy-path button, and `+N −N`.
final class DiffFileHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffFileHeader")

    var onToggle: (() -> Void)?
    var onCopyPath: (() -> Void)?

    private let chevron = GhostIconButton(symbol: Icon.chevronDown, size: 20, symbolSize: 11)
    private let glyph = NSImageView()
    private let pathLabel = NSTextField.label(size: Typography.rowSize)
    private let copyButton = GhostIconButton(symbol: Icon.copy, size: 20, symbolSize: 10, toolTip: "Copy path")
    private let statsLabel = NSTextField.label(size: Typography.smallSize)
    private var copiedReset: DispatchWorkItem?
    private var path = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        glyph.imageScaling = .scaleNone
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [chevron, glyph, pathLabel, copyButton, spacer, statsLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(4, after: chevron)
        stack.setCustomSpacing(2, after: pathLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        chevron.onClick = { [weak self] in self?.onToggle?() }
        copyButton.onClick = { [weak self] in self?.copyPath() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(entry: DiffFileEntry, collapsed: Bool, palette: Palette) {
        path = entry.path
        chevron.setSymbol(collapsed ? Icon.chevronRight : Icon.chevronDown, size: 11)
        chevron.toolTip = collapsed ? "Expand diff" : "Collapse diff"
        chevron.setAccessibilityLabel(collapsed ? "Expand \(entry.path)" : "Collapse \(entry.path)")

        let file = entry.file
        let (symbol, tint): (String, NSColor) = switch file.kind {
        case .added, .untracked: ("plus.square", palette.diffAdditionForeground)
        case .deleted: ("minus.square", palette.diffDeletionForeground)
        case .renamed, .copied: ("arrow.right.square", palette.infoForeground)
        default: ("square.dotted", palette.infoForeground.mixed(with: palette.mutedForeground, fraction: 0.5))
        }
        glyph.image = NSImage.symbol(symbol, size: 12)
        glyph.contentTintColor = tint

        let title = NSMutableAttributedString()
        let font = Typography.ui(Typography.rowSize, weight: .medium)
        func appendPath(_ path: String) {
            if let slash = path.lastIndex(of: "/") {
                title.append(NSAttributedString(string: String(path[...slash]), attributes: [.font: font, .foregroundColor: palette.mutedForeground]))
                title.append(NSAttributedString(string: String(path[path.index(after: slash)...]), attributes: [.font: font, .foregroundColor: palette.foreground]))
            } else {
                title.append(NSAttributedString(string: path, attributes: [.font: font, .foregroundColor: palette.foreground]))
            }
        }
        if (file.kind == .renamed || file.kind == .copied), let old = file.oldPath, let new = file.newPath, old != new {
            appendPath(old)
            title.append(NSAttributedString(string: " → ", attributes: [.font: font, .foregroundColor: palette.mutedForeground]))
            appendPath(new)
        } else {
            appendPath(entry.path)
        }
        pathLabel.attributedStringValue = title
        pathLabel.toolTip = entry.path

        statsLabel.attributedStringValue = DiffStatText.make(additions: entry.additions, deletions: entry.deletions, palette: palette,
                                                             size: Typography.smallSize, muteZero: true)
        copyButton.setSymbol(Icon.copy, size: 10)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        onCopyPath?()
        copyButton.setSymbol(Icon.check, size: 10)
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copyButton.setSymbol(Icon.copy, size: 10) }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }

    override func mouseUp(with event: NSEvent) {
        // Clicking the header's empty space toggles it, like pierre's header.
        if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onToggle?()
        }
    }
}

/// Row container: file headers are AppKit group rows (they float at the top while their file
/// scrolls) drawn on the panel background with a hairline; other rows are transparent.
final class DiffTableRowView: NSTableRowView {
    var palette: Palette = PaletteCenter.shared.palette {
        didSet { needsDisplay = true }
    }

    /// The first file's header has no top hairline.
    var isFirstFile = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard isGroupRowStyle else { return }
        palette.background.setFill()
        bounds.fill()
        palette.border.setFill()
        if !isFirstFile || isFloating {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if isFloating {
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// "+N −N" in the diff colors (T3 Code's `DiffStatLabel`), mono.
@MainActor
enum DiffStatText {
    static func make(additions: Int, deletions: Int, palette: Palette, size: CGFloat, muteZero: Bool = false) -> NSAttributedString {
        let font = Typography.mono(size)
        let text = NSMutableAttributedString()
        let addColor = muteZero && additions == 0 ? palette.mutedForeground : palette.diffAdditionForeground
        let delColor = muteZero && deletions == 0 ? palette.mutedForeground : palette.diffDeletionForeground
        text.append(NSAttributedString(string: "+\(compactDiffCount(additions))", attributes: [.font: font, .foregroundColor: addColor]))
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        text.append(NSAttributedString(string: "-\(compactDiffCount(deletions))", attributes: [.font: font, .foregroundColor: delColor]))
        return text
    }
}

extension NSImage {
    /// A copy of a template image filled with `color` (for drawing in `draw(_:)`).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension NSColor {
    /// The color at `fraction` of its own opacity (Tailwind's `border/65`); tokens that already
    /// carry alpha (dark `border`, `accent`, `input`) stay faint.
    func fading(_ fraction: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * fraction)
    }
}

/// Panels' stand-in for lucide `FileDiff` (the diff tab, the Changes row).
let diffGlyph = "plus.forwardslash.minus"
