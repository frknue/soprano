import AppKit
import SopranoAgentsCore

/// SF Symbols the sidebar and chat header use beyond the shared `Icon` set (lucide names).
enum SidebarSymbol {
    static let folderGit = "folder"                 // FolderGit2: worktree indicator
    static let ellipsis = "ellipsis"                // More actions
    static let xmark = "xmark"                      // Clear search
    static let plus = "plus"
    static let pinOff = "pin.slash"
    static let archive = "archivebox"
    static let trash = "trash"
    static let pencil = "pencil"
    static let refresh = "arrow.clockwise"
    static let mailOpen = "envelope.open"
    static let folderTree = "folder"
    static let hash = "number"
    static let messageSquare = "message"
    static let textSearch = "text.magnifyingglass"
    static let undo2 = "arrow.uturn.backward"
}

/// `SidebarMenuButton size="icon"`: a square icon button with the sidebar's row-hover fill
/// (`text-sidebar-muted-foreground/80`, hover `bg-sidebar-row-hover text-sidebar-foreground`).
final class SidebarIconButton: InteractiveView {
    private let imageView = NSImageView()
    private let side: CGFloat
    /// Pressed toggle look (filter active).
    var isOn = false {
        didSet { applyPalette(palette) }
    }

    init(symbol: String, size: CGFloat = 28, symbolSize: CGFloat = 14, label: String) {
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        layer?.cornerRadius = Radius.lg
        imageView.image = NSImage.symbol(symbol, size: symbolSize)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        toolTip = label
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        applyPalette(palette)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func applyPalette(_ palette: Palette) {
        let active = isEnabled && (isHovered || isOn)
        layer?.backgroundColor = (active ? palette.sidebarRowHover : .clear).cgColor
        imageView.contentTintColor = !isEnabled
            ? palette.sidebarMutedForeground.alphaScaled(by: 0.5)
            : active ? palette.sidebarForeground : palette.sidebarMutedForeground.alphaScaled(by: 0.8)
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// A text action inside a row ("✓ Settle", "⋯", "↶"): `text-xs text-muted-foreground hover:text-foreground`.
final class RowActionButton: InteractiveView {
    private let imageView = NSImageView()
    private let label = NSTextField.label("", size: Typography.smallSize)

    init(symbol: String, title: String? = nil, symbolSize: CGFloat = 11, accessibility: String) {
        super.init(frame: .zero)
        imageView.image = NSImage.symbol(symbol, size: symbolSize, weight: .medium)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        if let title {
            label.stringValue = title
            addSubview(label)
        }
        toolTip = accessibility
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibility)
        applyPalette(palette)
    }

    /// Width for its content with `px-1.5` padding.
    var fittingWidth: CGFloat {
        let iconWidth: CGFloat = 14
        guard !label.stringValue.isEmpty else { return iconWidth + 12 }
        return 6 + iconWidth + 4 + ceil(label.intrinsicContentSize.width) + 4 + 6
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        imageView.frame = NSRect(x: 6, y: midY - 8, width: 14, height: 16)
        if !label.stringValue.isEmpty {
            let size = label.intrinsicContentSize
            label.frame = NSRect(x: 24, y: midY - size.height / 2, width: ceil(size.width) + 4, height: size.height)
        }
    }

    override func applyPalette(_ palette: Palette) {
        let tint = isHovered ? palette.foreground : palette.mutedForeground
        imageView.contentTintColor = tint
        label.textColor = tint
    }
}

/// The project favicon stand-in: a project monogram (two glyphs on a 14 % tint of the
/// project color, `rounded-[25%]`, mono 8.25 bold in a 16 pt tile).
final class ProjectMonogramView: PaletteView {
    private var name: String?

    var projectName: String? {
        get { name }
        set {
            guard newValue != name else { return }
            name = newValue
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let name else { return }
        let colors = palette.projectIconColors
        let color = colors[ProjectIdentity.colorIndex(name, count: colors.count)]
        let side = min(bounds.width, bounds.height)
        let tile = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        color.alphaScaled(by: 0.14).setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.25, yRadius: side * 0.25).fill()

        let text = ProjectIdentity.monogram(name)
        let scale = side / 16
        let font = NSFont.monospacedSystemFont(ofSize: 8.25 * scale, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        // SVG text: baseline at y 10.8 of 16, squeezed to 12 (two glyphs) or 6 wide.
        let targetWidth = (text.count == 1 ? 6 : 12) * scale
        let horizontal = min(1, targetWidth / max(size.width, 1))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: tile.midX, yBy: tile.minY + 10.8 * scale)
        transform.scaleX(by: horizontal, yBy: 1)
        transform.concat()
        string.draw(at: NSPoint(x: -size.width / 2, y: -font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// `MiddleTruncate`: one line, ellipsis in the middle (branch names).
extension NSTextField {
    static func middleTruncating(size: CGFloat) -> NSTextField {
        let field = NSTextField.label("", size: size)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.lineBreakMode = .byTruncatingMiddle
        return field
    }
}

/// The inline rename input (`rounded-sm border bg-card px-1 text-sm font-medium`). Enter and
/// blur commit, Escape cancels; the owner gets exactly one callback.
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    override class var cellClass: AnyClass? {
        get { InlineRenameCell.self }
        set {}
    }

    init(text: String, fontSize: CGFloat = Typography.bodySize) {
        super.init(frame: .zero)
        stringValue = text
        font = Typography.ui(fontSize, weight: .medium)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        wantsLayer = true
        layer?.cornerRadius = Radius.sm
        layer?.borderWidth = 1
        delegate = self
        let palette = PaletteCenter.shared.palette
        textColor = palette.foreground
        layer?.backgroundColor = palette.card.cgColor
        layer?.borderColor = palette.primary.cgColor
        setAccessibilityLabel("Rename thread")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the caret in the field with everything selected.
    func beginEditing() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit {
            onCommit?(stringValue)
        } else {
            onCancel?()
        }
    }
}

/// Text vertically centered with `px-1` padding, for drawing and for the field editor.
final class InlineRenameCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        let top = max(0, (rect.height - height) / 2)
        return NSRect(x: rect.minX + 4, y: rect.minY + top, width: max(0, rect.width - 8), height: min(base.height, height))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

extension NSColor {
    /// Tailwind's `color/NN`: scales the token's own alpha (translucent dark-mode tokens such as
    /// `--border` stay translucent), unlike `withAlphaComponent`, which replaces it.
    func alphaScaled(by factor: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * factor)
    }
}
