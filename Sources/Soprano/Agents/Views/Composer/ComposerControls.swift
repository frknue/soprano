import AppKit
import SopranoAgentsCore

/// Composer symbols (kept with the composer; `Icon` holds the shared ones).
extension Icon {
    static let bot = "cpu"                                   // Build mode
    static let pencilRuler = "pencil.and.ruler"              // Plan mode
    static let cornerUpRight = "arrow.uturn.right"           // Steer
    static let listPlus = "text.badge.plus"                  // Queue
    static let zap = "bolt.fill"                             // Fast mode
    static let gauge = "gauge.with.dots.needle.33percent"    // Traits without effort
    static let ellipsis = "ellipsis"                         // More approval options
    static let close = "xmark"
    static let folder = "folder"
    static let folderGit = "folder.badge.plus"               // New worktree
    static let file = "doc"
    static let messageCircle = "bubble.left"                 // No project
    static let plus = "plus"
}

/// A borderless chip in the composer footer (`sm`, h28, 14 medium,
/// foreground 80%, muted 16 pt icons) or the context strip (`xs`, h24, 12 regular).
final class ComposerChip: InteractiveView {
    enum Size {
        case regular
        case context
    }

    private let size: Size
    private let leadingImage = NSImageView()
    private let label = NSTextField.label()
    private let trailingImage = NSImageView()
    private let stack = NSStackView()
    private var leadingPadding: NSLayoutConstraint?
    private var trailingPadding: NSLayoutConstraint?

    /// The popup the chip opens is showing (`data-popup-open`).
    var isOpen = false {
        didSet { applyPalette(palette) }
    }

    /// Effort word next to the model name: muted until hovered or open.
    var mutesTitle = false {
        didSet { applyPalette(palette) }
    }

    /// Read-only chips show their label without hover or press.
    var isInteractive = true {
        didSet { applyPalette(palette) }
    }

    enum ImageTint {
        /// Muted icon (regular chips), label color (context chips).
        case automatic
        /// The label's color (provider mark next to the model name).
        case text
        /// The image's own colors (Claude's mark).
        case original
    }

    var leadingTint: ImageTint = .automatic {
        didSet { applyPalette(palette) }
    }

    init(size: Size = .regular) {
        self.size = size
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        label.font = size == .regular ? Typography.ui(Typography.bodySize, weight: .medium) : Typography.ui(Typography.smallSize)
        for imageView in [leadingImage, trailingImage] {
            imageView.imageScaling = .scaleNone
            imageView.isHidden = true
            imageView.setContentHuggingPriority(.required, for: .horizontal)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = size == .regular ? 6 : 4
        stack.setViews([leadingImage, label, trailingImage], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let padding: CGFloat = size == .regular ? 8 : 7
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding)
        let trailing = trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: padding)
        leadingPadding = leading
        trailingPadding = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: size == .regular ? 28 : 24),
        ])
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    func configure(title: String?, image: NSImage?, trailing: NSImage? = nil) {
        label.stringValue = title ?? ""
        label.isHidden = title == nil
        leadingImage.image = image
        leadingImage.isHidden = image == nil
        trailingImage.image = trailing
        trailingImage.isHidden = trailing == nil
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    func setPadding(leading: CGFloat, trailing: CGFloat) {
        leadingPadding?.constant = leading
        trailingPadding?.constant = trailing
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        super.mouseUp(with: event)
    }

    override func applyPalette(_ palette: Palette) {
        let active = isInteractive && (isHovered || isOpen)
        layer?.backgroundColor = (active ? palette.accent : .clear).cgColor
        let base: NSColor = switch size {
        case .regular: palette.foreground.withAlphaComponent(0.8)
        case .context: palette.isDark ? palette.mutedForeground : palette.foreground.withAlphaComponent(0.7)
        }
        let text = active ? palette.foreground : (mutesTitle ? palette.mutedForeground : base)
        label.textColor = isEnabled ? text : text.withAlphaComponent(0.64)
        let iconTint = size == .regular ? (active ? palette.foreground : palette.mutedForeground) : label.textColor
        leadingImage.contentTintColor = switch leadingTint {
        case .automatic: iconTint
        case .text: label.textColor
        case .original: nil
        }
        trailingImage.contentTintColor = mutesTitle && !active ? palette.mutedForeground : iconTint
        alphaValue = isPressed ? 0.9 : 1
    }
}

/// The round primary button: send (arrow up), steer, queue, or stop.
final class ComposerPrimaryButton: InteractiveView {
    private(set) var action: ComposerPrimaryAction = .sendDisabled
    private let symbolView = NSImageView()
    private let glyphLayer = CAShapeLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        layer?.cornerRadius = 16
        symbolView.imageScaling = .scaleNone
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        glyphLayer.lineCap = .round
        glyphLayer.lineJoin = .round
        layer?.addSublayer(glyphLayer)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        update(.sendDisabled, tooltip: "Submit message")
    }

    func update(_ action: ComposerPrimaryAction, tooltip: String) {
        self.action = action
        isEnabled = action != .sendDisabled
        toolTip = tooltip
        setAccessibilityLabel(action == .stop ? "Stop generation" : tooltip)
        switch action {
        case .steer: symbolView.image = NSImage.symbol(Icon.cornerUpRight, size: 14, weight: .semibold)
        case .queue: symbolView.image = NSImage.symbol(Icon.listPlus, size: 14, weight: .semibold)
        case .send, .sendDisabled, .stop: symbolView.image = nil
        }
        symbolView.isHidden = symbolView.image == nil
        needsLayout = true
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        // Glyphs in a 14 pt (arrow) or 12 pt (stop square) box centered in the 32 pt circle, flipped.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.frame = bounds
        let path = CGMutablePath()
        switch action {
        case .send, .sendDisabled:
            let origin = CGPoint(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
            path.move(to: point(7, 11.5))
            path.addLine(to: point(7, 2.5))
            path.move(to: point(3, 6.5))
            path.addLine(to: point(7, 2.5))
            path.addLine(to: point(11, 6.5))
            glyphLayer.lineWidth = 1.8
        case .stop:
            let rect = CGRect(x: (bounds.width - 8) / 2, y: (bounds.height - 8) / 2, width: 8, height: 8)
            path.addRoundedRect(in: rect, cornerWidth: 1.5, cornerHeight: 1.5)
            glyphLayer.lineWidth = 0
        case .steer, .queue:
            break
        }
        glyphLayer.path = path
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let foreground: NSColor
        switch action {
        case .sendDisabled:
            layer?.backgroundColor = palette.foreground.withAlphaComponent(0.12).cgColor
            foreground = palette.mutedForeground
        case .stop:
            layer?.backgroundColor = palette.error.withAlphaComponent(isHovered ? 1 : 0.9).cgColor
            foreground = .white
        case .send, .steer, .queue:
            let fill = isHovered ? palette.primary.mixed(with: palette.background, fraction: 0.1) : palette.primary
            layer?.backgroundColor = fill.cgColor
            foreground = palette.primaryForeground
        }
        if action == .stop {
            glyphLayer.fillColor = foreground.cgColor
            glyphLayer.strokeColor = nil
        } else {
            glyphLayer.fillColor = nil
            glyphLayer.strokeColor = foreground.cgColor
        }
        symbolView.contentTintColor = foreground
        let scale: CGFloat = isHovered && isEnabled && action != .stop ? 1.05 : 1
        layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        alphaValue = isPressed ? 0.9 : 1
    }
}

/// `messageActionPill`: the rounded-full primary pill ("Next question", "Submit answers").
final class ComposerPillButton: InteractiveView {
    private let label = NSTextField.label("", size: Typography.bodySize, weight: .medium)

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    init(_ title: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = 14
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
        ])
        setAccessibilityRole(.button)
        self.title = title
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let fill = isHovered && isEnabled ? palette.primary.mixed(with: palette.background, fraction: 0.1) : palette.primary
        layer?.backgroundColor = fill.cgColor
        label.textColor = palette.primaryForeground
        alphaValue = isEnabled ? (isPressed ? 0.9 : 1) : 0.64
    }
}

/// A small switch for menus: primary track when on.
final class ComposerSwitch: PaletteView {
    var isOn = false {
        didSet { applyPalette(palette) }
    }

    private let thumb = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 16))
        layer?.cornerRadius = 8
        thumb.cornerRadius = 6
        layer?.addSublayer(thumb)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (isOn ? palette.primary : palette.input).cgColor
        thumb.backgroundColor = (palette.isDark && !isOn ? palette.foreground : NSColor.white).cgColor
        thumb.frame = CGRect(x: isOn ? bounds.width - 14 : 2, y: 2, width: 12, height: 12)
        CATransaction.commit()
    }
}

/// The radio of a question option (`OptionRadio`): outline circle, primary dot when checked.
final class ComposerRadioMark: PaletteView {
    var isChecked = false {
        didSet { applyPalette(palette) }
    }

    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        dot.cornerRadius = 3
        dot.frame = CGRect(x: 5, y: 5, width: 6, height: 6)
        layer?.addSublayer(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isChecked ? palette.primary : (palette.isDark ? palette.input.composerFaded(0.32) : palette.background)).cgColor
        layer?.borderColor = (isChecked ? palette.primary : palette.input).cgColor
        dot.backgroundColor = palette.primaryForeground.cgColor
        dot.isHidden = !isChecked
    }
}

/// A small outlined badge ("Default").
final class ComposerBadge: PaletteView {
    private let label = NSTextField.label("", size: 10, weight: .medium)

    init(_ text: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm
        layer?.borderWidth = 1
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.composerFaded(0.32) : palette.background).cgColor
        layer?.borderColor = palette.input.cgColor
        label.textColor = palette.foreground
    }
}

/// A 1 pt divider in `border` at 70% (horizontal unless `vertical`).
final class ComposerDivider: PaletteView {
    init(vertical: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        (vertical ? widthAnchor : heightAnchor).constraint(equalToConstant: 1).isActive = true
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.composerFaded(0.7).cgColor
    }
}

/// A menu row that fills with `accent` on hover (Fast Mode).
final class ComposerHoverRow: InteractiveView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.sm
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.accent : .clear).cgColor
    }
}

extension NSStackView {
    /// Fills the width the composer is given instead of hugging its content (the chat column
    /// sizes the composer at a lower priority than a stack's default hugging).
    func fillsWidth() {
        setHuggingPriority(.defaultLow, for: .horizontal)
        if orientation == .horizontal { distribution = .fill }
    }
}

/// Flexible space in a horizontal stack.
@MainActor
func composerSpacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return spacer
}

extension NSColor {
    /// Scales the color's own alpha (dark palette tokens such as `input` and `border` carry
    /// theirs; `withAlphaComponent` would replace it).
    func composerFaded(_ factor: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * factor)
    }
}

/// A vertical column that stretches every visible view to its full width (or centers it at its
/// natural width) and stacks them top to bottom; hidden views take no space. (`NSStackView`
/// only hugs arranged views to its leading edge, so it cannot give a view the composer's
/// full width.)
final class ComposerColumn: NSView {
    /// Views centered at their own width instead of stretched.
    var centersViews = false {
        didSet { needsUpdateConstraints = true }
    }

    private(set) var views: [NSView] = []
    private var spacingAfter: [ObjectIdentifier: CGFloat] = [:]
    private var installed: [NSLayoutConstraint] = []
    private var observations: [NSKeyValueObservation] = []
    var spacing: CGFloat {
        didSet { needsUpdateConstraints = true }
    }

    var insets: NSEdgeInsets {
        didSet { needsUpdateConstraints = true }
    }

    init(_ views: [NSView] = [], spacing: CGFloat = 0, insets: NSEdgeInsets = NSEdgeInsets()) {
        self.spacing = spacing
        self.insets = insets
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in views { add(view) }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        views.append(view)
        observations.append(view.observe(\.isHidden) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsUpdateConstraints = true }
        })
        needsUpdateConstraints = true
    }

    /// Removes every view (rows of a list).
    func removeAll() {
        observations = []
        for view in views { view.removeFromSuperview() }
        views = []
        spacingAfter = [:]
        rebuild()
    }

    func setSpacing(_ spacing: CGFloat, after view: NSView) {
        spacingAfter[ObjectIdentifier(view)] = spacing
        needsUpdateConstraints = true
    }

    override func updateConstraints() {
        rebuild()
        super.updateConstraints()
    }

    /// Pins the visible views edge to edge, top to bottom.
    func rebuild() {
        NSLayoutConstraint.deactivate(installed)
        var constraints: [NSLayoutConstraint] = []
        var previous: NSView?
        for view in views where !view.isHidden {
            if centersViews {
                constraints.append(view.centerXAnchor.constraint(equalTo: centerXAnchor))
                constraints.append(view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: insets.left))
                constraints.append(view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insets.right))
            } else {
                constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left))
                constraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right))
            }
            if let previous {
                let gap = spacingAfter[ObjectIdentifier(previous)] ?? spacing
                constraints.append(view.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: gap))
            } else {
                constraints.append(view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top))
            }
            previous = view
        }
        if let previous {
            constraints.append(previous.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom))
        } else {
            constraints.append(heightAnchor.constraint(equalToConstant: 0))
        }
        NSLayoutConstraint.activate(constraints)
        installed = constraints
    }
}

/// A multi-line label that wraps at whatever width layout gives it.
final class ComposerWrappingLabel: NSTextField {
    static func make(size: CGFloat = Typography.bodySize, weight: NSFont.Weight = .regular, maximumLines: Int = 0) -> ComposerWrappingLabel {
        let label = ComposerWrappingLabel(wrappingLabelWithString: "")
        label.font = Typography.ui(size, weight: weight)
        label.maximumNumberOfLines = maximumLines
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        return label
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(preferredMaxLayoutWidth - newSize.width) > 0.5 else { return }
        preferredMaxLayoutWidth = newSize.width
        invalidateIntrinsicContentSize()
    }
}
