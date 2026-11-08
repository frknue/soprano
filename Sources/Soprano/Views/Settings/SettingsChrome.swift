import AppKit

/// The settings screen's modal surface, ported from Soprano Agents'
/// `OverlayWindow`: the window dimmed with the background at 60 % (dark
/// 64 %) and one centered card on it (max 1280×960, 32 pt clear of every
/// edge, `rounded-2xl`, 1 pt edge, dialog shadow). It lives inside the main
/// window's content view rather than a child window, so it shares the
/// window's keyboard focus and the snapshot harness renders it.
///
/// A click on the backdrop and Esc call `onClose`; Esc steps aside while the
/// focused control consumes it (a recording Prefix key).
final class SettingsOverlayView: PaletteView {
    static let maxSize = NSSize(width: 1280, height: 960)
    static let margin: CGFloat = 32

    var onClose: (() -> Void)?
    /// Offered Esc before it closes the screen; true when the page used it
    /// (clearing a filter).
    var onEscape: (() -> Bool)?
    /// The card's content: it clips to the card's corners.
    let content = SettingsClippingView()
    private let card = SettingsOverlayCardView()
    private let cardShadow = SettingsOverlayShadowView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        content.layer?.cornerRadius = Radius.xxl
        content.layer?.masksToBounds = true
        for view in [cardShadow, card] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        // Preferred sizes sit below the window's "stay put" priority (500),
        // so the card never grows the main window.
        let width = card.widthAnchor.constraint(equalToConstant: Self.maxSize.width)
        width.priority = NSLayoutConstraint.Priority(450)
        let height = card.heightAnchor.constraint(equalToConstant: Self.maxSize.height)
        height.priority = NSLayoutConstraint.Priority(450)
        let inset = SettingsOverlayShadowView.inset
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, height,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Self.margin * 2),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -Self.margin * 2),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            cardShadow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: -inset),
            cardShadow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: inset),
            cardShadow.topAnchor.constraint(equalTo: card.topAnchor, constant: -inset),
            cardShadow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: inset),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.withAlphaComponent(palette.isDark ? 0.64 : 0.6).cgColor
    }

    /// Clicks outside the card land here; clicks on card space no control
    /// handles travel up the responder chain to here too and are ignored.
    override func mouseDown(with event: NSEvent) {
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard hitTest(point) === self else { return }
        onClose?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The workspace underneath must not drag the window or take scroll.
    override var mouseDownCanMoveWindow: Bool { false }
    override func scrollWheel(with event: NSEvent) {}

    /// AppKit offers Esc to key equivalents before the first responder's
    /// `keyDown`; a control that needs Esc itself keeps it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 53, modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
           (window?.firstResponder as? EscapeConsumingControl)?.consumesEscape != true {
            if onEscape?() != true { onClose?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The card (`dialog-glass … rounded-2xl border`): background fill and a
/// 1 pt foreground edge at 8 % (light 10 %).
final class SettingsOverlayCardView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.xxl
        layer?.borderWidth = 1
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.08 : 0.1).cgColor
    }
}

/// Draws the card's drop shadow `0 24px 64px -24px rgb(0 0 0 / 65%)` around
/// a rounded rect `inset` points inside its bounds (drawn, so snapshots
/// render it too).
final class SettingsOverlayShadowView: PaletteView {
    static let inset: CGFloat = 80

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = palette.isDark
        context.saveGState()
        // Flipped view: positive y moves the shadow down.
        context.setShadow(
            offset: CGSize(width: 0, height: 18),
            blur: dark ? 56 : 44,
            color: NSColor.black.withAlphaComponent(dark ? 0.7 : 0.28).cgColor
        )
        let card = bounds.insetBy(dx: Self.inset + 12, dy: Self.inset + 12)
        context.addPath(CGPath(roundedRect: card, cornerWidth: Radius.xxl, cornerHeight: Radius.xxl, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}

/// A flipped, layer-backed container that clips its subviews to its
/// rounded layer.
final class SettingsClippingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

/// The left navigation (`w-60 bg-sidebar border-e`): "Settings", one row per
/// page with its SF Symbol, the active one filled, and "Open settings.json"
/// at the bottom.
final class SettingsNavView: PaletteView {
    static let width: CGFloat = 240

    var onSelect: ((SettingsTab) -> Void)?
    var onOpenFile: (() -> Void)?
    private var items: [SettingsTab: SettingsNavItem] = [:]
    private let rule = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(rule)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let heading = SettingsLabel("Settings", size: Typography.bodySize, weight: .semibold) { $0.sidebarForeground }
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        for tab in SettingsTab.allCases {
            let item = SettingsNavItem(title: tab.title, symbol: tab.symbolName)
            item.onClick = { [weak self] in self?.onSelect?(tab) }
            items[tab] = item
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let file = SettingsNavItem(title: "Open settings.json", symbol: "doc.text")
        file.onClick = { [weak self] in self?.onOpenFile?() }
        file.translatesAutoresizingMaskIntoConstraints = false
        addSubview(file)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            heading.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.topbarHeight / 2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topbarHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            file.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            file.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            file.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            file.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
        ])
        applyPalette(palette)
    }

    func update(selected: SettingsTab) {
        for (tab, item) in items { item.isActive = tab == selected }
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.sidebar.cgColor
        rule.backgroundColor = palette.sidebarBorder.cgColor
    }
}

/// `SidebarMenuButton` (h32, `text-sm`, 16 pt icon); the active row is filled
/// and medium weight.
final class SettingsNavItem: InteractiveView {
    private let icon = NSImageView()
    private let label: SettingsLabel
    var isActive = false {
        didSet {
            applyPalette(palette)
            setAccessibilitySelected(isActive)
        }
    }

    init(title: String, symbol: String) {
        label = SettingsLabel(title, size: Typography.bodySize) { $0.sidebarForeground }
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        icon.image = NSImage.symbol(symbol, size: 14)
        icon.imageScaling = .scaleNone
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func applyPalette(_ palette: Palette) {
        let fill: NSColor = isActive
            ? (palette.isDark ? palette.sidebarRowActive : palette.foreground.withAlphaComponent(0.06))
            : (isHovered ? (palette.isDark ? palette.sidebarRowHover : palette.foreground.withAlphaComponent(0.04)) : .clear)
        layer?.backgroundColor = fill.cgColor
        icon.contentTintColor = isActive ? palette.sidebarForeground : palette.sidebarMutedForeground
        label.font = Typography.ui(Typography.bodySize, weight: isActive ? .medium : .regular)
    }
}
