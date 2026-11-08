import AppKit

/// Composer symbols (kept with the composer; `Icon` holds the shared ones).
enum ComposerIcon {
    static let steer = "arrow.uturn.right"
    static let queue = "text.badge.plus"
    static let restart = "arrow.clockwise"
    static let ellipsis = "ellipsis"
    static let close = "xmark"
    static let lock = "lock"
    static let chevronUp = "chevron.up"
}

/// A borderless chip in the composer footer (`sm`, h28, 14 medium, foreground 80%, muted 16 pt icons).
final class ComposerChip: InteractiveView {
    private let leadingImage = NSImageView()
    private let label = NSTextField.label()
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

    init() {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        label.font = Typography.ui(Typography.bodySize, weight: .medium)
        leadingImage.imageScaling = .scaleNone
        leadingImage.isHidden = true
        leadingImage.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setViews([leadingImage, label], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let trailing = trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 8)
        leadingPadding = leading
        trailingPadding = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    func configure(title: String?, image: NSImage?) {
        label.stringValue = title ?? ""
        label.isHidden = title == nil
        leadingImage.image = image
        leadingImage.isHidden = image == nil
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    func setPadding(leading: CGFloat, trailing: CGFloat) {
        leadingPadding?.constant = leading
        trailingPadding?.constant = trailing
    }

    override func applyPalette(_ palette: Palette) {
        let active = isHovered || isOpen
        layer?.backgroundColor = (active ? palette.accent : .clear).cgColor
        let text = active ? palette.foreground : (mutesTitle ? palette.mutedForeground : palette.foreground.withAlphaComponent(0.8))
        label.textColor = isEnabled ? text : text.withAlphaComponent(0.64)
        leadingImage.contentTintColor = active ? palette.foreground : palette.mutedForeground
        alphaValue = isPressed ? 0.9 : 1
    }
}

/// The round primary button: send (arrow up), steer, queue, stop (dimmed while stopping), or
/// restart once the agent stopped.
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

    func update(_ action: ComposerPrimaryAction, tooltip: String, stopping: Bool = false) {
        self.action = action
        isEnabled = action != .sendDisabled && !stopping
        toolTip = stopping ? "Stopping…" : tooltip
        setAccessibilityLabel(action == .stop ? (stopping ? "Stopping" : "Stop generation") : tooltip)
        switch action {
        case .steer: symbolView.image = NSImage.symbol(ComposerIcon.steer, size: 14, weight: .semibold)
        case .queue: symbolView.image = NSImage.symbol(ComposerIcon.queue, size: 14, weight: .semibold)
        case .restart: symbolView.image = NSImage.symbol(ComposerIcon.restart, size: 14, weight: .semibold)
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
        case .steer, .queue, .restart:
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
            layer?.backgroundColor = palette.error.withAlphaComponent(!isEnabled ? 0.45 : isHovered ? 1 : 0.9).cgColor
            foreground = .white
        case .send, .steer, .queue, .restart:
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
            constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left))
            constraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right))
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
