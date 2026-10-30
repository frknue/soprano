import AppKit
import SopranoAgentsCore

/// Row surfaces of the Thread details card (`threadDetailsPanelStyles.ts`): transparent at rest,
/// `black/3.5%` (light) or `white/8%` (dark) on hover or while their menu is open.
@MainActor
enum DetailsSurface {
    static func hover(_ palette: Palette) -> NSColor {
        palette.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.035)
    }

    /// Label color of rows: `text-foreground/80`.
    static func text(_ palette: Palette) -> NSColor {
        palette.foreground.withAlphaComponent(0.8)
    }
}

/// One clickable part of a details row: `h-8 rounded-lg px-2.5 gap-2.5`, a 16 pt muted icon, the
/// 13 pt medium label, optional trailing accessories.
final class DetailsRowButton: InteractiveView {
    enum Part {
        /// A whole row.
        case row
        /// The left part of a split row.
        case primary
        /// The 32 pt chevron of a split row.
        case secondary
    }

    let part: Part
    let iconView = NSImageView()
    let label = NSTextField.label(size: Typography.rowSize, weight: .medium)
    private let stack = NSStackView()
    /// Keeps the hover fill while its menu is open.
    var isMenuOpen = false {
        didSet { applyPalette(palette) }
    }

    /// Fill while the row reports progress (`bg-black/[0.035]`).
    var isHighlighted = false {
        didSet { applyPalette(palette) }
    }

    /// Icon color; nil = muted foreground.
    var iconTint: NSColor? {
        didSet { applyPalette(palette) }
    }

    init(part: Part, symbol: String? = nil, title: String = "") {
        self.part = part
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        switch part {
        case .row: break
        case .primary: layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .secondary: layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        if let symbol { iconView.image = NSImage.symbol(symbol, size: 13) }
        label.stringValue = title
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        if part == .secondary {
            iconView.image = NSImage.symbol(Icon.chevronDown, size: 11, weight: .medium)
            stack.addArrangedSubview(iconView)
        } else {
            stack.addArrangedSubview(iconView)
            stack.addArrangedSubview(label)
        }
        addSubview(stack)
        var constraints = [
            heightAnchor.constraint(equalToConstant: 32),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if part == .secondary {
            constraints += [
                widthAnchor.constraint(equalToConstant: 32),
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            ]
        } else {
            constraints += [
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityRole(.button)
        if !title.isEmpty { setAccessibilityLabel(title) }
        applyPalette(palette)
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    /// Adds a trailing accessory (badge, stats) after a flexible gap.
    func addTrailing(_ view: NSView) {
        if !stack.arrangedSubviews.contains(where: { $0.identifier?.rawValue == "spacer" }) {
            let spacer = NSView()
            spacer.identifier = NSUserInterfaceItemIdentifier("spacer")
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            stack.addArrangedSubview(spacer)
        }
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(view)
    }

    override func applyPalette(_ palette: Palette) {
        let filled = (isHovered && isEnabled) || isMenuOpen || isHighlighted
        layer?.backgroundColor = (filled ? DetailsSurface.hover(palette) : .clear).cgColor
        label.textColor = isEnabled ? DetailsSurface.text(palette) : DetailsSurface.text(palette).withAlphaComponent(0.5)
        iconView.contentTintColor = iconTint ?? palette.mutedForeground
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// A split row: primary action left, chevron menu right, a 1×16 hairline between them that shows
/// while the pair is hovered or its menu is open.
final class DetailsSplitRow: PaletteView {
    let primary: DetailsRowButton
    let secondary = DetailsRowButton(part: .secondary)
    private let separator = NSView()
    private var trackingArea: NSTrackingArea?
    private var isGroupHovered = false {
        didSet { applyPalette(palette) }
    }

    init(symbol: String?, title: String, menuLabel: String) {
        primary = DetailsRowButton(part: .primary, symbol: symbol, title: title)
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        separator.wantsLayer = true
        secondary.setAccessibilityLabel(menuLabel)
        secondary.toolTip = menuLabel
        for subview in [primary, separator, secondary] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: leadingAnchor),
            primary.topAnchor.constraint(equalTo: topAnchor),
            primary.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: primary.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            secondary.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            secondary.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondary.topAnchor.constraint(equalTo: topAnchor),
            secondary.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        applyPalette(palette)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isGroupHovered = true }
    override func mouseExited(with event: NSEvent) { isGroupHovered = false }

    override func applyPalette(_ palette: Palette) {
        let active = isGroupHovered || secondary.isMenuOpen
        separator.layer?.backgroundColor = (active ? palette.border.fading(0.65) : .clear).cgColor
    }
}

/// A 24 pt icon action at the end of a row ("Reveal in Finder").
final class DetailsIconAction: InteractiveView {
    private let iconView = NSImageView()

    init(symbol: String, toolTip: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        iconView.image = NSImage.symbol(symbol, size: 12)
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        self.toolTip = toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? DetailsSurface.hover(palette) : .clear).cgColor
        iconView.contentTintColor = isHovered ? palette.foreground : palette.mutedForeground
    }

    override func mouseDown(with event: NSEvent) {
        // Keeps the click from reaching the row underneath.
        super.mouseDown(with: event)
    }
}

/// Pull request badge of the branch row: `#N` in the state's color.
final class PullRequestBadge: PaletteView {
    private let label = NSTextField.label(size: Typography.smallSize, weight: .medium)
    private let icon = NSImageView()
    private var state: PullRequestInfo.State = .open

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol("arrow.triangle.pull", size: 10)
        icon.imageScaling = .scaleNone
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        applyPalette(palette)
    }

    func configure(number: Int, state: PullRequestInfo.State) {
        label.stringValue = "#\(number)"
        self.state = state
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let color: NSColor = switch state {
        case .open: palette.successForeground
        case .draft: palette.mutedForeground
        case .closed: palette.errorForeground
        case .merged: palette.mergedForeground
        }
        label.textColor = color
        icon.contentTintColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.1).cgColor
    }
}

extension NSMenu {
    /// Pops the menu up below `view`, keeping `row`'s hover fill while it is open.
    @MainActor
    func popUp(below view: NSView, marking row: DetailsRowButton? = nil, alignRight: Bool = false) {
        row?.isMenuOpen = true
        let x = alignRight ? view.bounds.width - max(minimumWidth, size.width) : 0
        popUp(positioning: nil, at: NSPoint(x: x, y: view.bounds.height + 4), in: view)
        row?.isMenuOpen = false
    }
}
