import AppKit
import SopranoAgentsCore

/// Content of a composer popover (model picker, traits menu, branch picker, …). Subclasses lay
/// themselves out with Auto Layout (fixed width, fitting height) and handle keys first.
class ComposerPopoverContent: PaletteView {
    /// Set by the popover; content calls it to dismiss itself.
    var requestClose: (() -> Void)?
    /// Set by the popover; content calls it after its fitting size changed (search filtered).
    var requestResize: (() -> Void)?

    /// The view that takes keyboard focus when the popover opens.
    var initialFocus: NSView? { nil }

    /// Keys reach the content before the focused field. Return true when handled.
    /// The default closes on Escape.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            requestClose?()
            return true
        }
        return false
    }
}

/// A floating surface of the composer: a borderless child window of the main window holding a
/// glass dropdown card (r8, popover fill, 10% outline, menu shadow). It closes on
/// Escape, on a click elsewhere, and when the composer closes it.
@MainActor
final class ComposerPopover {
    enum Side {
        case above
        case below
    }

    enum Alignment {
        case leading
        case center
        case trailing
    }

    /// Room around the card for its shadow.
    static let margin: CGFloat = 24
    static let gap: CGFloat = 6

    let content: ComposerPopoverContent
    private let window: ComposerPopoverWindow
    private let card: ComposerPopoverCard
    private weak var anchor: NSView?
    private weak var parent: NSWindow?
    private var side: Side = .above
    private var alignment: Alignment = .leading
    private var mouseMonitor: Any?
    private var isClosing = false

    /// Called once after the popover closed (by Escape, outside click, selection or `close()`).
    var onClose: (() -> Void)?

    var isShown: Bool { window.isVisible }

    init(content: ComposerPopoverContent) {
        self.content = content
        card = ComposerPopoverCard(content: content)
        window = ComposerPopoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let root = ComposerPopoverShadow(frame: window.contentLayoutRect)
        root.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.margin),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.margin),
        ])
        window.contentView = root
        window.keyHandler = { [weak content] event in content?.handleKey(event) ?? false }
        content.requestClose = { [weak self] in self?.close() }
        content.requestResize = { [weak self] in self?.reposition() }
    }

    func show(anchoredTo anchor: NSView, side: Side, alignment: Alignment) {
        guard let parent = anchor.window else { return }
        self.anchor = anchor
        self.parent = parent
        self.side = side
        self.alignment = alignment
        window.appearance = PaletteCenter.shared.palette.appearance
        reposition()
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
        window.makeKey()
        if let focus = content.initialFocus {
            window.makeFirstResponder(focus)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            MainActor.assumeIsolated {
                guard let self, incoming.window !== self.window else { return }
                self.close()
            }
            return incoming
        }
    }

    /// Sizes the card to its content and places it next to the anchor, inside the parent window.
    func reposition() {
        guard let anchor, let parent, anchor.window === parent else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x: CGFloat = switch alignment {
        case .leading: anchorRect.minX
        case .center: anchorRect.midX - size.width / 2
        case .trailing: anchorRect.maxX - size.width
        }
        x = min(max(x, parent.frame.minX + 8), parent.frame.maxX - size.width - 8)
        let y: CGFloat = switch side {
        case .above: anchorRect.maxY + Self.gap
        case .below: anchorRect.minY - Self.gap - size.height
        }
        let frame = NSRect(x: x - Self.margin, y: y - Self.margin, width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        window.setFrame(frame, display: true)
    }

    func close() {
        guard !isClosing, window.isVisible || window.parent != nil else { return }
        isClosing = true
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        let parent = window.parent ?? self.parent
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        parent?.makeKey()
        onClose?()
        onClose = nil
    }
}

/// Borderless child window that can take keys; keys reach the popover content first.
final class ComposerPopoverWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The visible card: rounded popover fill and 10% outline; clips its content.
private final class ComposerPopoverCard: PaletteView {
    private let clip = PaletteView()

    init(content: NSView) {
        super.init(frame: .zero)
        clip.layer?.cornerRadius = Radius.lg
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        clip.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        clip.addSubview(content)
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        layer?.cornerRadius = Radius.lg
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.popover.cgColor
        clip.layer?.backgroundColor = palette.popover.cgColor
        clip.layer?.borderColor = palette.foreground.withAlphaComponent(0.1).cgColor
    }
}

/// The popover window's content: draws the menu shadow (`0 16px 40px -18px` black 55%,
/// 80% dark) under the card, inside the window's margin.
private final class ComposerPopoverShadow: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: ComposerPopover.margin, dy: ComposerPopover.margin)
        guard card.width > 0, card.height > 0 else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.8 : 0.4)
        shadow.shadowBlurRadius = 24
        // The view is flipped: positive height moves the shadow down.
        shadow.shadowOffset = NSSize(width: 0, height: 10)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: card.insetBy(dx: 10, dy: 6), xRadius: Radius.lg, yRadius: Radius.lg).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }
}

/// A combobox search input: magnifier, borderless 14 pt field, `border/70` underline.
final class ComposerSearchField: PaletteView, NSTextFieldDelegate {
    let field = NSTextField()
    private let icon = NSImageView()
    private let underline = ComposerDivider()
    var onChange: ((String) -> Void)?

    var text: String { field.stringValue }

    init(placeholder: String) {
        super.init(frame: .zero)
        icon.image = NSImage.symbol(Icon.search, size: 13)
        icon.imageScaling = .scaleNone
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.ui(Typography.bodySize)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = placeholder
        for view in [icon, field, underline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            field.heightAnchor.constraint(equalToConstant: 20),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            underline.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyPalette(palette)
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.mutedForeground.withAlphaComponent(0.55)
        field.textColor = palette.foreground
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: palette.placeholder,
                .font: Typography.ui(Typography.bodySize),
            ])
        }
    }
}

/// One row of a composer popover list (`ComboboxItem` / `MenuItem`): min height 28, r4, px 8,
/// 14 pt; the current value has a 6% foreground fill, the highlighted row 9%.
final class ComposerListRow: InteractiveView {
    struct Model {
        var title: String
        var subtitle: String?
        var image: NSImage?
        var tintsImage = true
        /// Small muted text at the end (branch badges).
        var trailingNote: String?
        /// Outline badge after the title ("Default").
        var badge: String?
        var kbd: String?
        var showsCheck = false
        var isChecked = false
        var isCurrent = false
        var isDisabled = false
        var toolTip: String?
        var titleFont: NSFont = Typography.ui(Typography.bodySize)
    }

    private(set) var model: Model
    private let imageView = NSImageView()
    private let titleLabel = NSTextField.label()
    private let subtitleLabel = ComposerWrappingLabel.make(size: Typography.smallSize, maximumLines: 3)
    private let noteLabel = NSTextField.label("", size: 10)
    private let checkView = NSImageView()
    private var badgeView: ComposerBadge?
    private var kbdView: KbdView?

    var isHighlighted = false {
        didSet { applyPalette(palette) }
    }

    /// Hovering a row highlights it (keyboard and mouse share one highlight).
    var onHover: (() -> Void)?

    init(_ model: Model) {
        self.model = model
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm
        imageView.imageScaling = .scaleNone
        imageView.image = model.image
        imageView.isHidden = model.image == nil
        titleLabel.font = model.titleFont
        titleLabel.stringValue = model.title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.stringValue = model.subtitle ?? ""
        subtitleLabel.isHidden = model.subtitle == nil
        noteLabel.stringValue = model.trailingNote ?? ""
        noteLabel.isHidden = model.trailingNote == nil
        checkView.image = NSImage.symbol(Icon.check, size: 12, weight: .medium)
        checkView.imageScaling = .scaleNone
        checkView.isHidden = !model.showsCheck
        checkView.alphaValue = model.isChecked ? 1 : 0

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(titleLabel)
        if let badge = model.badge {
            let badgeView = ComposerBadge(badge)
            titleRow.addArrangedSubview(badgeView)
            self.badgeView = badgeView
        }
        let texts = ComposerColumn([titleRow, subtitleLabel], spacing: 2)
        texts.setContentHuggingPriority(.init(1), for: .horizontal)
        texts.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 6
        trailing.addArrangedSubview(noteLabel)
        if let kbd = model.kbd {
            let kbdView = KbdView(kbd)
            trailing.addArrangedSubview(kbdView)
            self.kbdView = kbdView
        }
        trailing.addArrangedSubview(checkView)
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [imageView, texts, trailing])
        row.orientation = .horizontal
        row.alignment = model.subtitle == nil ? .centerY : .top
        row.spacing = 8
        row.fillsWidth()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            imageView.widthAnchor.constraint(equalToConstant: model.image == nil ? 0 : 16),
        ])
        isEnabled = !model.isDisabled
        toolTip = model.toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(model.title)
        applyPalette(palette)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled { onHover?() }
    }

    override func applyPalette(_ palette: Palette) {
        let fill: NSColor = if isEnabled && (isHighlighted || isHovered) {
            palette.foreground.withAlphaComponent(0.09)
        } else if model.isCurrent {
            palette.foreground.withAlphaComponent(0.06)
        } else {
            .clear
        }
        layer?.backgroundColor = fill.cgColor
        alphaValue = isEnabled ? 1 : 0.64
        titleLabel.textColor = palette.foreground
        subtitleLabel.textColor = palette.mutedForeground.withAlphaComponent(0.8)
        noteLabel.textColor = palette.mutedForeground.withAlphaComponent(0.45)
        imageView.contentTintColor = model.tintsImage ? palette.mutedForeground : nil
        checkView.contentTintColor = palette.foreground
    }
}

/// A list of `ComposerListRow`s with one keyboard/mouse highlight, scrolling past `maxHeight`.
final class ComposerListView: PaletteView {
    private let scrollView = NSScrollView()
    private let document = ComposerFlippedView()
    private let stack = ComposerColumn(spacing: 2)
    private var heightConstraint: NSLayoutConstraint?
    private(set) var rows: [ComposerListRow] = []
    private var actions: [() -> Void] = []
    let maxHeight: CGFloat
    private let insets: NSEdgeInsets

    private(set) var highlightedIndex: Int?

    init(maxHeight: CGFloat, insets: NSEdgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)) {
        self.maxHeight = maxHeight
        self.insets = insets
        super.init(frame: .zero)
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Replaces the rows. `actions[i]` runs when row i is chosen.
    func setRows(_ models: [ComposerListRow.Model], actions: [() -> Void], highlight: Int?) {
        stack.removeAll()
        rows = models.map(ComposerListRow.init)
        self.actions = actions
        for (index, row) in rows.enumerated() {
            stack.add(row)
            row.onClick = { [weak self] in self?.choose(index) }
            row.onHover = { [weak self] in self?.setHighlight(index) }
        }
        stack.rebuild()
        let contentHeight = rows.isEmpty ? 0 : stack.fittingSize.height + insets.top + insets.bottom
        heightConstraint?.constant = min(contentHeight, maxHeight)
        highlightedIndex = nil
        setHighlight(highlight)
    }

    var isEmpty: Bool { rows.isEmpty }

    func setHighlight(_ index: Int?) {
        let valid = index.flatMap { rows.indices.contains($0) && rows[$0].isEnabled ? $0 : nil }
        if let old = highlightedIndex, rows.indices.contains(old) { rows[old].isHighlighted = false }
        highlightedIndex = valid
        if let valid {
            rows[valid].isHighlighted = true
            layoutSubtreeIfNeeded()
            rows[valid].scrollToVisible(rows[valid].bounds)
        }
    }

    /// Moves the highlight by `delta`, skipping disabled rows.
    func moveHighlight(by delta: Int) {
        guard !rows.isEmpty else { return }
        var index = highlightedIndex ?? (delta > 0 ? -1 : rows.count)
        for _ in rows.indices {
            index += delta
            guard rows.indices.contains(index) else { return }
            if rows[index].isEnabled {
                setHighlight(index)
                return
            }
        }
    }

    func chooseHighlighted() -> Bool {
        guard let highlightedIndex else { return false }
        choose(highlightedIndex)
        return true
    }

    func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        actions[index]()
    }
}

final class ComposerFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Small muted group label in menus ("Reasoning", "Permissions", "Workspace").
@MainActor
func composerMenuLabel(_ text: String) -> NSTextField {
    NSTextField.label(text, size: Typography.smallSize, weight: .medium)
}
