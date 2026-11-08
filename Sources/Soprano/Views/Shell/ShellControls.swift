import AppKit

// Soprano Agents' text buttons, tab-style segmented control, composer card
// and page header, as AppKit controls (`NSButton` / `NSControl`) so they keep
// target/action, key equivalents, keyboard access and accessibility.

/// Agents' `TextButton` (`h-7 rounded-lg px-2.5 text-[13px] font-medium`):
/// outline (input ring on a faint fill), primary, or ghost, with an optional
/// keyboard hint chip after the title (`KbdView`).
final class ShellTextButton: NSButton {
    enum Variant {
        case outline
        case primary
        case ghost
        /// `destructiveOutline`: a faint error ring and error text.
        case destructive
    }

    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 10
    private static let keycapGap: CGFloat = 6

    let variant: Variant
    var keycap: String? {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false

    override var title: String {
        didSet {
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    init(title: String, keycap: String? = nil, variant: Variant = .outline) {
        self.variant = variant
        self.keycap = keycap
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        // Laid out by constraints wherever it sits: an autoresizing mask
        // would pin a centered button's frame to its zero origin.
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityLabel(title)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Kept for call sites that re-theme every control; colors come from the palette.
    func apply(theme: AppTheme) {
        needsDisplay = true
    }

    private var titleFont: NSFont { Typography.ui(Typography.rowSize, weight: .medium) }
    private var keycapFont: NSFont { Typography.ui(Typography.tinySize, weight: .medium) }

    private var keycapSize: NSSize {
        guard let keycap, !keycap.isEmpty else { return .zero }
        let width = ceil((keycap as NSString).size(withAttributes: [.font: keycapFont]).width)
        return NSSize(width: max(18, width + 8), height: 18)
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let keycapWidth = keycapSize.width > 0 ? Self.keycapGap + keycapSize.width : 0
        return NSSize(width: Self.horizontalPadding * 2 + titleWidth + keycapWidth, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        var fill: NSColor = .clear
        var text = palette.foreground
        var border: NSColor?
        switch variant {
        case .primary:
            fill = isHovered ? palette.primary.mixed(with: palette.background, fraction: 0.1) : palette.primary
            text = palette.primaryForeground
        case .outline:
            fill = isHovered ? palette.accent
                : palette.isDark ? palette.input.shellScaled(by: 0.32) : palette.popover
            border = palette.input
        case .ghost:
            fill = isHovered ? palette.accent : .clear
        case .destructive:
            fill = isHovered ? palette.error.withAlphaComponent(0.08) : .clear
            border = palette.error.withAlphaComponent(0.4)
            text = palette.errorForeground
        }
        if !isEnabled { text = text.withAlphaComponent(0.5) }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Radius.lg, yRadius: Radius.lg)
        fill.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: text]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        var x = Self.horizontalPadding
        let contentWidth = intrinsicContentSize.width - Self.horizontalPadding * 2
        x = max(Self.horizontalPadding, (bounds.width - contentWidth) / 2)
        (title as NSString).draw(
            at: NSPoint(x: x, y: (bounds.height - titleSize.height) / 2),
            withAttributes: attributes
        )
        if let keycap, keycapSize.width > 0 {
            let chip = NSRect(
                x: x + ceil(titleSize.width) + Self.keycapGap,
                y: (bounds.height - keycapSize.height) / 2,
                width: keycapSize.width,
                height: keycapSize.height
            )
            let chipFill = variant == .primary ? palette.primaryForeground.withAlphaComponent(0.18) : palette.foreground.withAlphaComponent(0.07)
            chipFill.setFill()
            NSBezierPath(roundedRect: chip, xRadius: Radius.sm, yRadius: Radius.sm).fill()
            let keyAttributes: [NSAttributedString.Key: Any] = [
                .font: keycapFont,
                .foregroundColor: variant == .primary ? text : palette.mutedForeground,
            ]
            let keySize = (keycap as NSString).size(withAttributes: keyAttributes)
            (keycap as NSString).draw(
                at: NSPoint(x: chip.midX - keySize.width / 2, y: chip.midY - keySize.height / 2),
                withAttributes: keyAttributes
            )
        }
        alphaValue = isHighlighted ? 0.85 : 1
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

/// A section heading in Agents' voice: sentence case, 12 pt medium, muted
/// (no uppercase eyebrow).
final class ShellHeadingLabel: NSTextField {
    var title: String {
        get { stringValue }
        set { stringValue = newValue }
    }

    init(title: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        stringValue = title
        font = Typography.ui(Typography.smallSize, weight: .medium)
        lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyPalette() }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        applyPalette()
    }

    private func applyPalette() {
        textColor = PaletteCenter.shared.palette.mutedForeground
    }
}

extension NSTextField {
    /// Sets a sentence-case Agents heading (12 pt medium, muted) where Folio
    /// set an uppercase eyebrow.
    @MainActor
    func setShellHeading(_ title: String) {
        attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: Typography.ui(Typography.smallSize, weight: .medium),
            .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
        ])
    }
}

/// A row of Agents tabs used as a segmented control (`h-6 rounded-md text-xs`,
/// active `bg-accent`, hover `bg-accent/60`). Sends its action when a click
/// picks an enabled segment.
final class ShellSegmentedControl: NSControl {
    private(set) var selectedSegment = 0
    private let titles: [String]
    private var segmentEnabled: [Bool]
    private var hoveredSegment: Int?
    private var trackingArea: NSTrackingArea?
    private static let segmentPadding: CGFloat = 10
    private static let gap: CGFloat = 2

    init(titles: [String]) {
        self.titles = titles
        segmentEnabled = titles.map { _ in true }
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.radioGroup)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var segmentCount: Int { titles.count }

    func apply(theme: AppTheme) {
        needsDisplay = true
    }

    func select(_ index: Int) {
        guard titles.indices.contains(index), index != selectedSegment else { return }
        selectedSegment = index
        needsDisplay = true
    }

    func setEnabled(_ isEnabled: Bool, forSegment index: Int) {
        guard segmentEnabled.indices.contains(index), segmentEnabled[index] != isEnabled else { return }
        segmentEnabled[index] = isEnabled
        needsDisplay = true
    }

    private func font(_ index: Int) -> NSFont {
        Typography.ui(Typography.smallSize, weight: index == selectedSegment ? .medium : .regular)
    }

    private var segmentRects: [NSRect] {
        var x: CGFloat = 0
        return titles.enumerated().map { index, title in
            let width = ceil((title as NSString).size(withAttributes: [.font: font(index)]).width) + Self.segmentPadding * 2
            defer { x += width + Self.gap }
            return NSRect(x: x, y: (bounds.height - ShellTabStyle.height) / 2, width: width, height: ShellTabStyle.height)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (segmentRects.last?.maxX ?? 0), height: ShellTabStyle.height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        for (index, rect) in segmentRects.enumerated() {
            let isActive = index == selectedSegment
            let isHovered = index == hoveredSegment && segmentEnabled[index]
            ShellTabStyle.draw(isActive: isActive, isHovered: isHovered, in: rect)
            var color = ShellTabStyle.textColor(isActive: isActive, isHovered: isHovered)
            if !segmentEnabled[index] { color = palette.mutedForeground.withAlphaComponent(0.45) }
            let attributes: [NSAttributedString.Key: Any] = [.font: font(index), .foregroundColor: color]
            let size = (titles[index] as NSString).size(withAttributes: attributes)
            (titles[index] as NSString).draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func segment(at point: NSPoint) -> Int? {
        segmentRects.firstIndex { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = segment(at: convert(event.locationInWindow, from: nil)),
              segmentEnabled[index], index != selectedSegment
        else { return }
        selectedSegment = index
        needsDisplay = true
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let next = segment(at: convert(event.locationInWindow, from: nil))
        guard next != hoveredSegment else { return }
        hoveredSegment = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Agents' composer card (`rounded-2xl border bg-card`, ring on focus), as the
/// surface behind a reply field.
final class ShellComposerSurface: NSView {
    var isFocused = false {
        didSet { applyPalette() }
    }

    var isInvalid = false {
        didSet { applyPalette() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.xxl
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyPalette() }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        applyPalette()
    }

    private func applyPalette() {
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.card.cgColor
        layer?.borderColor = (isInvalid ? palette.error
            : isFocused ? palette.primary.shellScaled(by: 0.55)
            : palette.border).cgColor
    }
}

/// The header of a full-window page (Agent Dashboard), in Agents' chat
/// header language: a 14 pt semibold title, a muted 13 pt subtitle, a ghost
/// "Done esc" button, and one `border` hairline. Clicks on empty space move
/// the window: the header sits in the title bar strip.
final class ShellPageHeaderView: NSView {
    static let height: CGFloat = Metrics.topbarHeight

    let closeButton = ShellTextButton(title: "Done", keycap: "esc", variant: .ghost)
    private let titleLabel = NSTextField.label("", size: Typography.bodySize, weight: .semibold)
    private let subtitleLabel = NSTextField.label("", size: Typography.rowSize)
    private let rule = NSView()
    private var titleLeading: NSLayoutConstraint!

    var onClose: (() -> Void)?

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    /// Muted meta text after the title; empty or nil hides it.
    var subtitle: String? {
        didSet {
            subtitleLabel.stringValue = subtitle ?? ""
            subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        }
    }

    var displayedSubtitle: String { subtitleLabel.stringValue }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rule.wantsLayer = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalentModifierMask = []
        closeButton.toolTip = "Return to the workspace (Esc)"
        for view in [titleLabel, subtitleLabel, closeButton, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            subtitleLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyPalette() }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        applyPalette()
    }

    private func applyPalette() {
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        titleLabel.textColor = palette.foreground
        subtitleLabel.textColor = palette.mutedForeground
        rule.layer?.backgroundColor = palette.border.cgColor
    }

    override func layout() {
        super.layout()
        let inset = max(Metrics.gutter, ShellTitlebar.trafficLightInset(for: self))
        if titleLeading.constant != inset { titleLeading.constant = inset }
    }

    override func mouseDown(with event: NSEvent) {
        ShellTitlebar.handleMouseDown(event, in: self)
    }

    /// AppKit offers Esc to key equivalents before the first responder's
    /// `keyDown`, so Done would win over a control that needs Esc.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, (window?.firstResponder as? EscapeConsumingControl)?.consumesEscape == true {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
