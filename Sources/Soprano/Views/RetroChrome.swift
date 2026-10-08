import AppKit
import CoreText

// Soprano's chrome design language, "Mission Control": square corners,
// hairline and double-rule dividers, small-caps pixel type, glowing indicator
// lamps, and a 70s racing stripe. Every chrome surface draws from these
// tokens and components so the look holds together across all palettes.

// MARK: - Metrics

enum Retro {
    static let hairline: CGFloat = 1
    /// Space between the two strokes of a double rule.
    static let ruleGap: CGFloat = 2
    static let doubleRule: CGFloat = hairline * 2 + ruleGap
    /// Chrome has no rounded corners; lamps are the only round shapes.
    static let cornerRadius: CGFloat = 0
    /// Height of buttons, keycaps and other single-line controls.
    static let controlHeight: CGFloat = 24
}

// MARK: - Type

/// Chrome typography.
///
/// Labels, titles, tabs, badges and buttons use Departure Mono, a pixel-grid
/// monospace bundled with the app (SIL OFL, shipped as
/// `LICENSE-departure-mono`). Its pixels sit on an 11 pt grid, so 11 and 22
/// are the only sizes that stay crisp. Lowercase renders as small caps, which
/// gives the console all-caps look without rewriting window titles, agent
/// names, or paths. Running text people read in full (descriptions, paths,
/// transcripts, input fields) uses the system monospace via `body`.
enum RetroFont {
    static let postScriptName = "DepartureMono-Regular"
    static let familyName = "Departure Mono"
    /// The pixel-perfect size. Titles use twice the grid.
    static let grid: CGFloat = 11

    /// Registers the bundled face for this process. Idempotent; the first
    /// `display` request does it implicitly.
    @discardableResult
    static func registerBundledFont() -> Bool { isRegistered }

    private static let isRegistered: Bool = {
        if NSFont(name: postScriptName, size: grid) != nil { return true }
        guard let url = fontURL else { return false }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        _ = error?.takeRetainedValue()
        return registered || NSFont(name: postScriptName, size: grid) != nil
    }()

    private static var fontURL: URL? {
        SopranoResources.bundle.url(forResource: postScriptName, withExtension: "woff2")
    }

    /// The pixel display face. Falls back to the system monospace when the
    /// bundled font cannot be loaded, so chrome never renders without text.
    static func display(_ size: CGFloat = grid, smallCaps: Bool = true) -> NSFont {
        displayFonts.font(size: size, smallCaps: smallCaps) {
            makeDisplay(size, smallCaps: smallCaps)
        }
    }

    /// Labels restyle on every agent update, and building the small-caps face
    /// from a font descriptor costs more than laying out the text it styles.
    private static let displayFonts = DisplayFontCache()

    private static func makeDisplay(_ size: CGFloat, smallCaps: Bool) -> NSFont {
        registerBundledFont()
        guard let font = NSFont(name: postScriptName, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        }
        guard smallCaps else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    /// Smooth monospace for running text.
    static func body(_ size: CGFloat = grid, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// An `@font-face` rule exposing the bundled face to WebKit content as
    /// `"Departure Mono"`. WebKit renders in a separate process that cannot
    /// see fonts registered in this one, so the face travels inline.
    static let cssFontFace: String = {
        guard let url = fontURL, let data = try? Data(contentsOf: url) else { return "" }
        return """
        @font-face {
          font-family: "\(familyName)";
          src: url(data:font/woff2;base64,\(data.base64EncodedString())) format("woff2");
          font-display: block;
        }
        """
    }()
}

/// Lock-protected rather than main-actor isolated because `RetroFont` is
/// called from nonisolated text builders as well as from views.
private final class DisplayFontCache: @unchecked Sendable {
    private struct Key: Hashable {
        let size: CGFloat
        let smallCaps: Bool
    }

    private let lock = NSLock()
    private var fonts: [Key: NSFont] = [:]

    func font(size: CGFloat, smallCaps: Bool, make: () -> NSFont) -> NSFont {
        let key = Key(size: size, smallCaps: smallCaps)
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] {
            return font
        }
        let font = make()
        fonts[key] = font
        return font
    }
}

// MARK: - Text

enum RetroText {
    /// Letter spacing for display labels, in points.
    static let tracking: CGFloat = 1

    /// A string in the display face: small caps, tracked, and optionally
    /// glowing like phosphor.
    static func display(
        _ text: String,
        color: NSColor,
        size: CGFloat = RetroFont.grid,
        tracking: CGFloat = RetroText.tracking,
        glow: Bool = false,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        var attributes: [NSAttributedString.Key: Any] = [
            .font: RetroFont.display(size),
            .foregroundColor: color,
            .kern: tracking,
            .paragraphStyle: paragraph,
        ]
        if glow {
            attributes[.shadow] = phosphorGlow(color)
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// The soft halo lit text and lamps carry.
    static func phosphorGlow(_ color: NSColor) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        return shadow
    }
}

extension NSTextField {
    /// Sets the label's text in the display face, keeping the field's own
    /// alignment and line break mode. `stringValue` stays `text`.
    func setRetroText(
        _ text: String,
        color: NSColor,
        size: CGFloat = RetroFont.grid,
        tracking: CGFloat = RetroText.tracking,
        glow: Bool = false
    ) {
        attributedStringValue = RetroText.display(
            text,
            color: color,
            size: size,
            tracking: tracking,
            glow: glow,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }
}

// MARK: - Rules

/// A console divider: one hairline, or two with a gap between them.
final class RetroRuleView: NSView {
    enum Axis {
        case horizontal
        case vertical
    }

    enum Style {
        case single
        case double

        var thickness: CGFloat {
            switch self {
            case .single: Retro.hairline
            case .double: Retro.doubleRule
            }
        }
    }

    let axis: Axis
    let style: Style
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(axis: Axis, style: Style = .double, color: NSColor = .separatorColor) {
        self.axis = axis
        self.style = style
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // A rule is exactly its stroke thick; stack views must never stretch it.
        let thicknessAxis: NSLayoutConstraint.Orientation = axis == .horizontal ? .vertical : .horizontal
        setContentHuggingPriority(.required, for: thicknessAxis)
        setContentCompressionResistancePriority(.required, for: thicknessAxis)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        switch axis {
        case .horizontal:
            NSSize(width: NSView.noIntrinsicMetric, height: style.thickness)
        case .vertical:
            NSSize(width: style.thickness, height: NSView.noIntrinsicMetric)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let line = Retro.hairline
        switch (axis, style) {
        case (.horizontal, .single):
            NSRect(x: bounds.minX, y: floor(bounds.midY - line / 2), width: bounds.width, height: line).fill()
        case (.horizontal, .double):
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: line).fill()
            NSRect(x: bounds.minX, y: bounds.maxY - line, width: bounds.width, height: line).fill()
        case (.vertical, .single):
            NSRect(x: floor(bounds.midX - line / 2), y: bounds.minY, width: line, height: bounds.height).fill()
        case (.vertical, .double):
            NSRect(x: bounds.minX, y: bounds.minY, width: line, height: bounds.height).fill()
            NSRect(x: bounds.maxX - line, y: bounds.minY, width: line, height: bounds.height).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Stripe

/// The 70s racing stripe: parallel bands in `ThemeColors.stripe`, either
/// slanted like a console decal or stacked as horizontal pinstripes.
final class RetroStripeView: NSView {
    enum Layout {
        case slanted
        case stacked
    }

    let layout: Layout
    var colors: [NSColor] {
        didSet { needsDisplay = true }
    }
    /// Space between bands.
    var gap: CGFloat = 2 {
        didSet { needsDisplay = true }
    }

    init(layout: Layout, colors: [NSColor] = []) {
        self.layout = layout
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !colors.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        let count = CGFloat(colors.count)
        switch layout {
        case .stacked:
            let bandHeight = max(1, (bounds.height - gap * (count - 1)) / count)
            for (index, color) in colors.enumerated() {
                // The first color sits on top so the stripe reads downward.
                let offset = CGFloat(index)
                let y = bounds.maxY - (offset + 1) * bandHeight - offset * gap
                color.setFill()
                NSRect(x: bounds.minX, y: y, width: bounds.width, height: bandHeight).fill()
            }
        case .slanted:
            let lean = bounds.height * 0.5
            let bandWidth = max(1, (bounds.width - lean - gap * (count - 1)) / count)
            for (index, color) in colors.enumerated() {
                let x = bounds.minX + CGFloat(index) * (bandWidth + gap)
                let band = NSBezierPath()
                band.move(to: NSPoint(x: x, y: bounds.minY))
                band.line(to: NSPoint(x: x + bandWidth, y: bounds.minY))
                band.line(to: NSPoint(x: x + bandWidth + lean, y: bounds.maxY))
                band.line(to: NSPoint(x: x + lean, y: bounds.maxY))
                band.close()
                color.setFill()
                band.fill()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Lamps

/// Round indicator lamps with a soft glow, like the status lights on a
/// console. The caller owns the lamp's size and corner radius.
@MainActor
enum RetroLamp {
    static func light(_ view: NSView, color: NSColor, lit: Bool = true) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.backgroundColor = color.cgColor
        layer.masksToBounds = false
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 3
        layer.shadowOpacity = lit ? 0.85 : 0
    }
}

// MARK: - Buttons

/// A square console key: hairline frame and a display-face label. A
/// prominent key is lit with the accent; any key lights up while pressed.
final class RetroButton: NSButton {
    enum Kind {
        case standard
        case prominent
    }

    static let horizontalPadding: CGFloat = 12

    var kind: Kind {
        didSet { needsDisplay = true }
    }
    private(set) var theme: AppTheme
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    init(
        title: String,
        theme: AppTheme,
        kind: Kind = .standard,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.theme = theme
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let width = ceil(label(color: .labelColor).size().width)
        return NSSize(width: width + Self.horizontalPadding * 2, height: Retro.controlHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        // A disabled key is never lit, so a prominent one cannot read as ready.
        let isPressed = isEnabled && isHighlighted
        let isLit = isPressed || (isEnabled && kind == .prominent)
        let isHot = isEnabled && isHovered
        let fill: NSColor = if isPressed {
            colors.accentStrong
        } else if isLit {
            colors.accent
        } else {
            isHot ? colors.bgOverlay : colors.bgRaised
        }
        let edge: NSColor = isLit ? fill : (isHot ? colors.accent : colors.borderStrong)
        let text: NSColor = if !isEnabled {
            colors.textMuted
        } else {
            isLit ? colors.bgPanel : colors.textPrimary
        }

        fill.setFill()
        bounds.fill()
        edge.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = Retro.hairline
        frame.stroke()

        let string = label(color: text)
        let size = string.size()
        string.draw(at: NSPoint(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2)
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func label(color: NSColor) -> NSAttributedString {
        RetroText.display(title, color: color, lineBreakMode: .byClipping)
    }
}

/// Borderless SF Symbol button for sidebar headers, toolbars and footers; its
/// tint switches to the hover color while the pointer is over it.
final class RetroIconButton: NSButton {
    static let defaultSize: CGFloat = 26

    private var normalTint: NSColor?
    private var hoverTint: NSColor?
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(
        symbolName: String,
        accessibilityLabel: String,
        pointSize: CGFloat = 13,
        size: CGFloat = RetroIconButton.defaultSize,
        target: AnyObject?,
        action: Selector?
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setSymbol(symbolName, accessibilityLabel: accessibilityLabel, pointSize: pointSize)
        toolTip = accessibilityLabel
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSymbol(_ symbolName: String, accessibilityLabel: String, pointSize: CGFloat = 13) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        setAccessibilityLabel(accessibilityLabel)
    }

    func setTints(normal: NSColor, hover: NSColor) {
        normalTint = normal
        hoverTint = hover
        applyTint()
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyTint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyTint()
    }

    private func applyTint() {
        contentTintColor = isHovered && isEnabled ? hoverTint : normalTint
    }
}

// MARK: - Headings

/// A section heading: a display-face title followed by a hairline running
/// to the trailing edge, `AGENTS ───────────`.
final class RetroHeadingView: NSView {
    let label = NSTextField(labelWithString: "")
    private let rule = RetroRuleView(axis: .horizontal, style: .single)
    private var theme: AppTheme
    private var isAccented: Bool

    var title: String {
        didSet { refresh() }
    }

    init(title: String, theme: AppTheme, accented: Bool = false) {
        self.title = title
        self.theme = theme
        self.isAccented = accented
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        addSubview(rule)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: Retro.hairline),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme, accented: Bool? = nil) {
        self.theme = theme
        if let accented {
            isAccented = accented
        }
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        label.setRetroText(title, color: isAccented ? colors.accent : colors.textMuted)
        rule.color = colors.borderStrong
    }
}
