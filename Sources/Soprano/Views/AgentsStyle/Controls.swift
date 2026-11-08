import AppKit

/// Content that scrolls under a still pointer gets no `mouseExited`, so a view that shows hover
/// re-checks the pointer whenever its enclosing clip view scrolls and drops a hover the pointer
/// left. Entering stays with AppKit's next mouse move: keyboard navigation scrolls lists too, and
/// a synthesized enter would move their highlight to whatever row sits under a resting pointer.
/// Attach it from `viewDidMoveToWindow`.
@MainActor
final class ScrollHoverSync: NSObject {
    private weak var view: NSView?
    private weak var clip: NSClipView?
    private let onPointerLeft: () -> Void

    init(_ view: NSView, onPointerLeft: @escaping () -> Void) {
        self.view = view
        self.onPointerLeft = onPointerLeft
    }

    /// Follows the view's current enclosing clip view (none once it leaves the window).
    func attach() {
        let next = view?.window == nil ? nil : view?.enclosingScrollView?.contentView
        guard next !== clip else { return }
        if let clip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) }
        clip = next
        guard let next else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: next)
    }

    @objc private func scrolled() {
        guard let view, let window = view.window else { return }
        if !Self.contains(window.mouseLocationOutsideOfEventStream, in: view) { onPointerLeft() }
    }

    /// Whether a window point lies in the visible part of `view`.
    static func contains(_ windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor else { return false }
        return view.visibleRect.contains(view.convert(windowPoint, from: nil))
    }
}

/// Base for custom-drawn controls: tracks hover and press, re-colors from the palette.
class InteractiveView: PaletteView {
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet { applyPalette(palette) }
    }

    private(set) var isHovered = false
    private(set) var isPressed = false
    private var trackingArea: NSTrackingArea?
    private lazy var scrollHover = ScrollHoverSync(self) { [weak self] in self?.pointerLeftByScrolling() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollHover.attach()
    }

    /// The list scrolled this view out from under the pointer. Routed through `mouseExited`, so
    /// subclasses' hover side effects run too.
    func pointerLeftByScrolling() {
        guard isHovered, let window,
              let event = NSEvent.enterExitEvent(
                  with: .mouseExited,
                  location: window.mouseLocationOutsideOfEventStream,
                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil,
                  eventNumber: 0, trackingNumber: 0, userData: nil
              ) else { return }
        mouseExited(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyPalette(palette)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        applyPalette(palette)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyPalette(palette)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        applyPalette(palette)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// For the snapshot harness and tests: hover without a mouse.
    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        applyPalette(palette)
    }
}

/// Ghost icon button / ghost toggle: a square SF Symbol
/// button with an accent hover fill. `isOn` shows the pressed toggle state.
final class GhostIconButton: InteractiveView {
    private let imageView = NSImageView()
    private let side: CGFloat

    var isOn = false {
        didSet { applyPalette(palette) }
    }

    /// Tint at rest; nil = muted foreground.
    var restingTint: NSColor? {
        didSet { applyPalette(palette) }
    }

    /// Fill at rest; nil = none. Owners set fills here, never on the layer: hover repaints it.
    var restingFill: NSColor? {
        didSet { applyPalette(palette) }
    }

    /// Fill while `isOn` (hovered or not); nil = accent.
    var onFill: NSColor? {
        didSet { applyPalette(palette) }
    }

    init(symbol: String, size: CGFloat = Metrics.titlebarControlSize, symbolSize: CGFloat = 15, toolTip: String? = nil) {
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
        self.toolTip = toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
        applyPalette(palette)
    }

    func setSymbol(_ name: String, size: CGFloat = 15) {
        imageView.image = NSImage.symbol(name, size: size)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func applyPalette(_ palette: Palette) {
        let active = isOn || isHovered
        let fill = isOn ? (onFill ?? palette.accent) : isHovered ? palette.accent : (restingFill ?? .clear)
        layer?.backgroundColor = fill.cgColor
        imageView.contentTintColor = !isEnabled
            ? palette.mutedForeground.withAlphaComponent(0.5)
            : active ? palette.foreground : (restingTint ?? palette.mutedForeground)
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// Text button with variants and sizes.
final class TextButton: InteractiveView {
    enum Variant {
        case primary
        case outline
        case ghost
        case destructive
        case destructiveOutline
        case secondary
    }

    enum Size {
        /// h24, text-xs.
        case xs
        /// h28.
        case sm
        /// h32.
        case regular

        var height: CGFloat {
            switch self {
            case .xs: 24
            case .sm: 28
            case .regular: 32
            }
        }

        var fontSize: CGFloat {
            self == .xs ? Typography.smallSize : Typography.rowSize
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .xs: 8
            case .sm: 10
            case .regular: 12
            }
        }
    }

    let variant: Variant
    let size: Size
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let stack = NSStackView()

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    init(_ title: String, symbol: String? = nil, variant: Variant = .outline, size: Size = .sm) {
        self.variant = variant
        self.size = size
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 0
        label.stringValue = title
        label.font = Typography.ui(size.fontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        if let symbol {
            iconView.image = NSImage.symbol(symbol, size: size == .xs ? 12 : 14)
            stack.addArrangedSubview(iconView)
        }
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: size.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -size.horizontalPadding),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        var fill: NSColor = .clear
        var text = palette.foreground
        var border: NSColor?
        switch variant {
        case .primary:
            fill = isHovered ? palette.primary.mixed(with: palette.background, fraction: 0.1) : palette.primary
            text = palette.primaryForeground
        case .outline:
            fill = isHovered ? palette.accent : (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.popover)
            border = palette.input
        case .ghost:
            fill = isHovered ? palette.accent : .clear
        case .secondary:
            fill = isHovered ? palette.accent : palette.secondary
        case .destructive:
            fill = palette.error.withAlphaComponent(isHovered ? 1 : 0.9)
            text = .white
        case .destructiveOutline:
            fill = isHovered ? palette.error.withAlphaComponent(0.08) : .clear
            border = palette.error.withAlphaComponent(0.4)
            text = palette.errorForeground
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        let tint = isEnabled ? text : text.withAlphaComponent(0.5)
        label.textColor = tint
        iconView.contentTintColor = tint
        alphaValue = isPressed ? 0.9 : 1
    }
}

/// Keyboard hint: `h-5 min-w-5 rounded bg-foreground/[0.07] px-1 text-xs`.
final class KbdView: PaletteView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm
        label.stringValue = text
        label.font = Typography.ui(Typography.tinySize, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(0.07).cgColor
        label.textColor = palette.mutedForeground
    }
}

extension NSTextField {
    /// Non-editable single-line label in the UI font.
    static func label(_ text: String = "", size: CGFloat = Typography.bodySize, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Typography.ui(size, weight: weight)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}
