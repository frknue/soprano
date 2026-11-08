import AppKit

// Soprano Agents' diff list rows (`Views/Panels/Diff/DiffRows.swift`,
// `DiffSurfaceViewController.swift`) over Soprano's whole-file git diff: stacked and split
// line rows with tint, change bar, line numbers and word highlights; the folded
// "N unmodified lines" strip; the sticky file header; the stacked | split toggle.

/// What one side of a line row shows.
struct SurfaceDiffSide {
    var kind: DiffLine.Kind
    var number: Int?
    var text: NSAttributedString
}

@MainActor
enum SurfaceDiffDrawing {
    static let headerHeight: CGFloat = 36
    static let foldHeight: CGFloat = 28
    static let endHeight: CGFloat = 8

    static func kind(_ kind: GitDiffRow.Kind) -> DiffLine.Kind {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .context, .filler: .context
        }
    }

    /// A row's text: syntax colors, the changed words on the word tint, tabs as four spaces,
    /// wrapped or on one clipped line.
    static func text(
        _ line: GitDiffLine,
        kind: DiffLine.Kind,
        tokens: [SyntaxToken]?,
        emphasis: NSRange?,
        wrap: Bool,
        style: DiffStyle
    ) -> NSAttributedString {
        let raw = SurfaceDiffDocument.displayText(line.text)
        let cut = raw.count > DiffLine.maximumDrawnLength ? String(raw.prefix(DiffLine.maximumDrawnLength)) : raw
        var attributes = style.wrappingAttributes
        if !wrap {
            let single = NSMutableParagraphStyle()
            single.lineBreakMode = .byClipping
            attributes[.paragraphStyle] = single
        }
        let text = NSMutableAttributedString(string: cut, attributes: attributes)
        let length = text.length
        for token in tokens ?? [] where token.range.location < length {
            let range = NSRange(location: token.range.location, length: min(token.range.length, length - token.range.location))
            text.addAttribute(.foregroundColor, value: style.syntaxColor(token.kind), range: range)
            if token.kind.isEmphasized {
                text.addAttribute(.font, value: style.semiboldFont, range: range)
            } else if token.kind.isItalic {
                text.addAttribute(.font, value: style.italicFont, range: range)
            }
        }
        if let emphasis, emphasis.location < length {
            let range = NSRange(location: emphasis.location, length: min(emphasis.length, length - emphasis.location))
            let color = kind == .added ? style.palette.diffAdditionWord : style.palette.diffDeletionWord
            text.addAttribute(.backgroundColor, value: color, range: range)
        }
        if cut.contains("\t") {
            text.mutableString.replaceOccurrences(of: "\t", with: "    ", options: [], range: NSRange(location: 0, length: length))
        }
        return text
    }

    /// One side (`minX..<maxX`) of a row: tint, bar, line number, then the text (wrapped, or on
    /// one line scrolled left by `offset`); a missing side is a muted filler.
    static func draw(
        _ side: SurfaceDiffSide?,
        from minX: CGFloat,
        to maxX: CGFloat,
        height: CGFloat,
        numberWidth: CGFloat,
        wrap: Bool,
        offset: CGFloat,
        style: DiffStyle
    ) {
        guard let side else {
            style.palette.foreground.withAlphaComponent(style.palette.isDark ? 0.035 : 0.025).setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
            return
        }
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
final class SurfaceDiffUnifiedLineView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffUnifiedLine")

    private var side: SurfaceDiffSide?
    private var style: DiffStyle?
    private var numberWidth: CGFloat = 0
    private var wrap = false
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset, !wrap { needsDisplay = true } }
    }
    /// The line is in the list's selection: drawn under the selection tint.
    var isLineSelected = false {
        didSet { if oldValue != isLineSelected { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(side: SurfaceDiffSide, numberWidth: CGFloat, wrap: Bool, textOffset: CGFloat, style: DiffStyle) {
        self.side = side
        self.style = style
        self.numberWidth = numberWidth
        self.wrap = wrap
        self.textOffset = textOffset
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        SurfaceDiffDrawing.draw(side, from: 0, to: bounds.width, height: bounds.height, numberWidth: numberWidth,
                                wrap: wrap, offset: textOffset, style: style)
        if isLineSelected {
            SurfaceText.selection(style.palette).setFill()
            bounds.fill(using: .sourceOver)
        }
    }
}

/// A split diff row: the old line left, the new line right, divided by a `border` hairline; a
/// missing side is a muted filler.
final class SurfaceDiffSplitLineView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffSplitLine")

    private var old: SurfaceDiffSide?
    private var new: SurfaceDiffSide?
    private var style: DiffStyle?
    private var numberWidth: CGFloat = 0
    private var wrap = false
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset, !wrap { needsDisplay = true } }
    }
    /// The selected side of the row (true: old, false: new), nil when the row is not selected.
    var selectedSide: Bool? {
        didSet { if oldValue != selectedSide { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func dividerX(rowWidth: CGFloat) -> CGFloat { floor(rowWidth / 2) }

    func configure(
        old: SurfaceDiffSide?,
        new: SurfaceDiffSide?,
        numberWidth: CGFloat,
        wrap: Bool,
        textOffset: CGFloat,
        style: DiffStyle
    ) {
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
        SurfaceDiffDrawing.draw(old, from: 0, to: divider, height: bounds.height, numberWidth: numberWidth,
                                wrap: wrap, offset: textOffset, style: style)
        SurfaceDiffDrawing.draw(new, from: divider + 1, to: bounds.width, height: bounds.height, numberWidth: numberWidth,
                                wrap: wrap, offset: textOffset, style: style)
        if let selectedSide, (selectedSide ? old : new) != nil {
            SurfaceText.selection(style.palette).setFill()
            let rect = selectedSide
                ? NSRect(x: 0, y: 0, width: divider, height: bounds.height)
                : NSRect(x: divider + 1, y: 0, width: bounds.width - divider - 1, height: bounds.height)
            rect.fill(using: .sourceOver)
        }
        style.palette.border.setFill()
        NSRect(x: divider, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// The strip before a block of lines (Agents' `DiffHunkView`): "N unmodified lines" (or the
/// `@@` range when nothing is hidden) and the enclosing declaration, on a muted strip. A
/// click on a fold shows its lines.
final class SurfaceDiffFoldView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffFold")

    var onExpand: (() -> Void)?
    private var text = NSAttributedString()
    private var style: DiffStyle?
    private var textX: CGFloat = 0
    private var isExpandable = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ fold: SurfaceDiffFold, numberWidth: CGFloat, style: DiffStyle) {
        self.style = style
        textX = numberWidth + DiffStyle.codeInset
        isExpandable = fold.hiddenLines > 0
        let palette = style.palette
        let small = Typography.mono(Typography.smallSize)
        let lead = fold.range ?? "\(fold.hiddenLines) unmodified \(fold.hiddenLines == 1 ? "line" : "lines")"
        let label = NSMutableAttributedString(string: lead, attributes: [.font: small, .foregroundColor: palette.mutedForeground])
        let section = fold.section.trimmingCharacters(in: .whitespaces)
        if !section.isEmpty {
            label.append(NSAttributedString(string: "   " + section, attributes: [
                .font: small, .foregroundColor: palette.mutedForeground.withAlphaComponent(0.8),
            ]))
        }
        text = label
        toolTip = isExpandable ? "Show \(lead)" : nil
        setAccessibilityRole(isExpandable ? .button : .staticText)
        setAccessibilityLabel(isExpandable ? "Show \(lead)" : lead)
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard isExpandable else { return false }
        onExpand?()
        return true
    }

    /// Taken here, so the mouse-up comes to this strip rather than the list's tracking.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isExpandable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onExpand?()
    }

    override func resetCursorRects() {
        if isExpandable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let palette = style.palette
        palette.foreground.withAlphaComponent(palette.isDark ? 0.04 : 0.03).setFill()
        bounds.fill(using: .sourceOver)
        palette.border.timelineAlpha(0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill(using: .sourceOver)
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
        if let image = NSImage.symbol("chevron.up.chevron.down", size: 10, weight: .medium) {
            let tinted = image.surfaceTinted(palette.mutedForeground)
            let size = tinted.size
            tinted.draw(in: NSRect(
                x: floor((textX - DiffStyle.codeInset - size.width) / 2),
                y: floor((bounds.height - size.height) / 2),
                width: size.width,
                height: size.height
            ))
        }
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - DiffStyle.codeTrailing), height: bounds.height).clip()
        text.draw(at: NSPoint(x: textX, y: floor((bounds.height - size.height) / 2)))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Space after the file's last row.
final class SurfaceDiffEndView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffEnd")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The file's sticky header (Agents' `DiffFileHeaderView`): collapse chevron, change glyph,
/// path (directory muted, name in the foreground), copy-path button, and `+N -N`.
final class SurfaceDiffFileHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SurfaceDiffFileHeader")

    var onToggle: (() -> Void)?

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

    func configure(_ document: SurfaceDiffDocument, staged: Bool, collapsed: Bool, palette: Palette) {
        path = document.path
        chevron.setSymbol(collapsed ? Icon.chevronRight : Icon.chevronDown, size: 11)
        chevron.toolTip = collapsed ? "Expand diff" : "Collapse diff"
        chevron.setAccessibilityLabel(collapsed ? "Expand \(document.path)" : "Collapse \(document.path)")

        let (symbol, tint): (String, NSColor) = switch document.change {
        case .added: ("plus.square", palette.diffAdditionForeground)
        case .deleted: ("minus.square", palette.diffDeletionForeground)
        case .modified: ("square.dotted", palette.infoForeground.mixed(with: palette.mutedForeground, fraction: 0.5))
        }
        glyph.image = NSImage.symbol(symbol, size: 12)
        glyph.contentTintColor = tint

        let title = NSMutableAttributedString()
        let font = Typography.ui(Typography.rowSize, weight: .medium)
        if let slash = document.path.lastIndex(of: "/") {
            title.append(NSAttributedString(string: String(document.path[...slash]), attributes: [
                .font: font, .foregroundColor: palette.mutedForeground,
            ]))
            title.append(NSAttributedString(string: String(document.path[document.path.index(after: slash)...]), attributes: [
                .font: font, .foregroundColor: palette.foreground,
            ]))
        } else {
            title.append(NSAttributedString(string: document.path, attributes: [.font: font, .foregroundColor: palette.foreground]))
        }
        if staged {
            title.append(NSAttributedString(string: "  Staged", attributes: [
                .font: Typography.ui(Typography.smallSize), .foregroundColor: palette.mutedForeground,
            ]))
        }
        pathLabel.attributedStringValue = title
        pathLabel.toolTip = document.path

        statsLabel.attributedStringValue = DiffStatText.make(
            additions: document.additions,
            deletions: document.deletions,
            palette: palette,
            size: Typography.smallSize,
            muteZero: true
        )
        copyButton.setSymbol(Icon.copy, size: 10)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copyButton.setSymbol(Icon.check, size: 10)
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copyButton.setSymbol(Icon.copy, size: 10) }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }

    /// Taken here, so the mouse-up comes to the header rather than the list's tracking.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        // Clicking the header's empty space toggles it.
        if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onToggle?()
        }
    }
}

/// Row container: the file header is an AppKit group row (it floats at the top while the file
/// scrolls) on the background with a hairline under it while floating; other rows are
/// transparent.
final class SurfaceDiffTableRowView: NSTableRowView {
    var palette: Palette = PaletteCenter.shared.palette {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isGroupRowStyle else { return }
        palette.background.setFill()
        bounds.fill()
        if isFloating {
            palette.border.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// The diff list (Agents' `DiffTableView`). Horizontal gestures (trackpad, ⇧ + wheel) scroll
/// the code text instead of the list when lines do not wrap; a gesture keeps the axis it
/// started on. F7 and ⇧F7 move between changes. Pressing a line and dragging (or
/// shift-clicking) selects whole lines across rows; ⌘C copies them, ⌘A selects every line,
/// Escape clears the selection, and a right click offers the owner's menu.
final class SurfaceDiffTableView: NSTableView {
    var scrollText: ((CGFloat) -> Bool)?
    var onFocus: (() -> Void)?
    /// F7 (true) and ⇧F7 (false): the next or previous change.
    var onNavigate: ((Bool) -> Void)?
    /// Whether a list row shows file lines (selection starts only on those).
    var isLineRow: ((Int) -> Bool)?
    /// A press on a line row: the row, the x in the table, and whether ⇧ extends the selection.
    var onSelectionBegin: ((Int, CGFloat, Bool) -> Void)?
    /// The row a drag has reached.
    var onSelectionExtend: ((Int) -> Void)?
    var onSelectAll: (() -> Void)?
    var onClearSelection: (() -> Void)?
    /// Copies the selection; false when nothing is selected.
    var onCopy: (() -> Bool)?
    var hasSelection: (() -> Bool)?
    /// The menu for a right click on a row (-1 outside the rows) at an x in the table.
    var contextMenu: ((Int, CGFloat) -> NSMenu?)?
    private var gestureIsHorizontal: Bool?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.onFocus?() }
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
        if event.keyCode == 53, hasSelection?() == true {
            onClearSelection?()
            return
        }
        super.keyDown(with: event)
    }

    /// The row under a point in the table; above or below the rows, the first or last row.
    func clampedRow(at point: NSPoint) -> Int {
        let row = row(at: point)
        guard row < 0 else { return row }
        return point.y < 0 ? 0 : max(0, numberOfRows - 1)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, isLineRow?(row) == true, let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(self)
        onSelectionBegin?(row, point.x, event.modifierFlags.contains(.shift))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard next.type == .leftMouseDragged else { break }
            autoscroll(with: next)
            onSelectionExtend?(clampedRow(at: convert(next.locationInWindow, from: nil)))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenu?(row(at: point), point.x)
    }

    @objc func copy(_ sender: Any?) {
        if onCopy?() != true { NSSound.beep() }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    /// ⌘C and ⌘A while the list has the keyboard, with or without an Edit menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where hasSelection?() == true:
            _ = onCopy?()
            return true
        case "a":
            onSelectAll?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): hasSelection?() == true
        case #selector(selectAll(_:)): true
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if !event.phase.isDisjoint(with: [.began, .mayBegin]) {
            gestureIsHorizontal = nil
        }
        let inGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let isHorizontal: Bool
        if inGesture, let locked = gestureIsHorizontal {
            isHorizontal = locked
        } else if dx == 0, dy == 0 {
            super.scrollWheel(with: event)
            return
        } else {
            isHorizontal = abs(dx) > abs(dy)
            if inGesture { gestureIsHorizontal = isHorizontal }
        }
        let delta = -dx * (event.hasPreciseScrollingDeltas ? 1 : 24)
        if isHorizontal, let scrollText, scrollText(delta) { return }
        super.scrollWheel(with: event)
    }
}

/// The segmented "Diff layout" toggle (Agents' `DiffLayoutToggle`): Stacked | Split.
final class SurfaceDiffLayoutToggle: PaletteView {
    var onChange: ((SurfaceDiffLayout) -> Void)?
    var layout: SurfaceDiffLayout = .unified {
        didSet { applyPalette(palette) }
    }

    let stacked = GhostIconButton(symbol: "rectangle.grid.1x2", size: 24, symbolSize: 11, toolTip: "Stacked diff view")
    let split = GhostIconButton(symbol: "rectangle.split.2x1", size: 24, symbolSize: 11, toolTip: "Split diff view")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        let stack = NSStackView(views: [stacked, split])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        stacked.onClick = { [weak self] in self?.onChange?(.unified) }
        split.onClick = { [weak self] in self?.onChange?(.split) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Diff layout")
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.06 : 0.05).cgColor
        stacked.isOn = layout == .unified
        split.isOn = layout == .split
        for button in [stacked, split] {
            button.onFill = palette.popover
            button.layer?.cornerRadius = Radius.md
        }
    }
}

/// Agents' small secondary label pill (the scope trigger's look, without a menu).
final class SurfaceDiffScopeLabel: PaletteView {
    private let label = NSTextField.label(size: Typography.smallSize, weight: .medium)

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.secondary.cgColor
        layer?.borderWidth = palette.isDark ? 0 : 1
        layer?.borderColor = palette.border.timelineAlpha(0.7).cgColor
        label.textColor = palette.foreground
    }
}

extension NSImage {
    /// A copy of a template image filled with `color` (for drawing in `draw(_:)`).
    func surfaceTinted(_ color: NSColor) -> NSImage {
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

/// A menu item's action as a closure (the item keeps it as its represented object, since a
/// menu item's target is weak).
final class SurfaceDiffMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
