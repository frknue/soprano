import AppKit
import SopranoAgentsCore

/// What row views ask the timeline to do. The timeline controller implements it; rows never
/// touch the engine or the workspace state themselves.
@MainActor
protocol TimelineRowDelegate: AnyObject {
    func timelineToggleFold(turnID: String)
    func timelineToggleGroup(_ groupID: String)
    func timelineToggleEntry(_ itemID: String)
    func timelineToggleMessage(_ messageID: String)
    func timelineTogglePlan(_ itemID: String)
    func timelineSetClosedFolders(turnID: String, paths: Set<String>)
    func timelineEditFromHere(turnID: String)
    func timelineRespond(approvalID: String, decision: ApprovalDecision)
    func timelineOpenDiff(turnOrdinal: Int, path: String?)
    func timelineSendQueuedNow(messageID: String)
    func timelineRemoveQueued(messageID: String)
    func timelineCopy(_ text: String)
}

/// Day-aware timestamps: "3:42 PM", "yesterday at 3:42 PM",
/// "3/14 3:42 PM", with the year when it differs.
enum TimelineFormat {
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return clock }
        if days == 1 { return "yesterday at \(clock)" }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "Mdyy")
        return "\(day.string(from: date)) \(clock)"
    }

    /// Tooltip: the full date and time.
    static func tooltip(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// Base of every timeline row: manual frame layout (`layoutRow(width:)` returns the content
/// height, which the list also uses for sizing), optional hover, find highlights.
class TimelineRowView: PaletteView {
    weak var delegate: TimelineRowDelegate?
    private(set) var row: TimelineRow?
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false
    private lazy var scrollHover = ScrollHoverSync(self) { [weak self] in self?.setHovered(false) }

    /// Rows that reveal controls on hover (message footers, timestamps).
    var tracksHover: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    /// Sets the row's content. Subclasses call super first.
    func configure(_ row: TimelineRow) {
        self.row = row
    }

    /// Lays out subviews for `width` and returns the content height (without the row spacing).
    func layoutRow(width: CGFloat) -> CGFloat { 0 }

    func applyFind(_ highlights: [FindHighlight]) {}

    /// Rect of a find match in this view's coordinates.
    func findRect(unit: Int, range: NSRange) -> NSRect? { nil }

    func hoverChanged() {}

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard tracksHover else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollHover.attach()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
}

// MARK: - Controls

/// The timeline's small button variants that `TextButton` lacks:
/// `ghost-muted` (muted text, accent hover), `inline` (text link, underline on hover) and icon-only.
final class TimelineButton: InteractiveView {
    enum Variant {
        case ghostMuted
        case ghost
        case outline
        /// Inline: no fill, medium weight, underline on hover.
        case inline(muted: Bool)
    }

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let variant: Variant
    private let fontSize: CGFloat
    private let height: CGFloat
    private var symbol: String?
    /// Icon and text tint override (Copy → ✓ in primary).
    var tint: NSColor? {
        didSet { applyPalette(palette) }
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            setAccessibilityLabel(newValue.isEmpty ? toolTip : newValue)
        }
    }

    init(_ title: String = "", symbol: String? = nil, variant: Variant = .ghostMuted, fontSize: CGFloat = Typography.smallSize, height: CGFloat = 24, toolTip: String? = nil) {
        self.variant = variant
        self.fontSize = fontSize
        self.height = height
        self.symbol = symbol
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        label.font = Typography.ui(fontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = title
        label.isHidden = title.isEmpty
        addSubview(label)
        if let symbol {
            iconView.image = NSImage.symbol(symbol, size: fontSize, weight: .medium)
            addSubview(iconView)
        }
        self.toolTip = toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? toolTip : title)
        applyPalette(palette)
    }

    func setSymbol(_ name: String?) {
        symbol = name
        iconView.image = name.map { NSImage.symbol($0, size: fontSize, weight: .medium) } ?? nil
        if name != nil, iconView.superview == nil { addSubview(iconView) }
        iconView.isHidden = name == nil
    }

    private var isInline: Bool {
        if case .inline = variant { return true }
        return false
    }

    private var padding: CGFloat { isInline ? 0 : (label.isHidden ? 0 : 8) }

    /// Width the button needs.
    var fittingWidth: CGFloat {
        let iconWidth: CGFloat = symbol == nil ? 0 : fontSize + 2
        if label.isHidden { return isInline ? iconWidth : height }
        let text = label.textFitWidth
        return padding * 2 + iconWidth + (symbol == nil ? 0 : 4) + text
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: height) }

    override func layout() {
        super.layout()
        let iconSize = fontSize + 2
        if label.isHidden {
            iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            return
        }
        var x = padding
        if symbol != nil {
            iconView.frame = NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            x += iconSize + 4
        }
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - x - padding), height: textHeight)
    }

    override func applyPalette(_ palette: Palette) {
        var text = palette.mutedForeground
        var fill: NSColor = .clear
        var border: NSColor?
        switch variant {
        case .ghostMuted:
            text = isHovered ? palette.foreground : palette.mutedForeground
            fill = isHovered ? palette.accent : .clear
        case .ghost:
            text = palette.foreground
            fill = isHovered ? palette.accent : .clear
        case .outline:
            text = palette.foreground
            fill = isHovered ? palette.accent : (palette.isDark ? palette.input.timelineAlpha(0.32) : palette.popover)
            border = palette.input
        case let .inline(muted):
            text = muted && !isHovered ? palette.mutedForeground : palette.foreground
        }
        if let tint { text = tint }
        if !isEnabled { text = text.timelineAlpha(0.5) }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.borderColor = border?.cgColor
        iconView.contentTintColor = text
        var attributes: [NSAttributedString.Key: Any] = [.font: Typography.ui(fontSize, weight: .medium), .foregroundColor: text]
        if isInline, isHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: attributes)
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// A Copy button that morphs to a check in the primary color for a moment (`MessageCopyButton`).
@MainActor
enum CopyButton {
    static func make(label: String = "Copy message", variant: TimelineButton.Variant = .ghostMuted, text: @escaping @MainActor () -> String, delegate: @escaping @MainActor () -> TimelineRowDelegate?) -> TimelineButton {
        let button = TimelineButton(symbol: Icon.copy, variant: variant, toolTip: label)
        button.onClick = { [weak button] in
            delegate()?.timelineCopy(text())
            button?.setSymbol(Icon.check)
            button?.tint = PaletteCenter.shared.palette.primary
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    button?.setSymbol(Icon.copy)
                    button?.tint = nil
                }
            }
        }
        return button
    }
}

/// A single-line label helper with a fixed color role.
extension NSTextField {
    static func timelineLabel(_ text: String = "", size: CGFloat = Typography.bodySize, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField.label(text, size: size, weight: weight)
        field.isSelectable = false
        return field
    }

    /// Height of one line in the field's font.
    var lineHeight: CGFloat {
        guard let font else { return 17 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Width the field needs to show its whole single-line text (cell padding included).
    var textFitWidth: CGFloat {
        guard let cell else { return ceil(attributedStringValue.size().width) + 6 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000)).width) + 1
    }
}

/// SF Symbol image view at 16 pt with a palette tint.
final class TimelineIconView: NSImageView {
    init(symbol: String = "", size: CGFloat = 14) {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyDown
        setSymbol(symbol, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) {
        image = name.isEmpty ? nil : NSImage.symbol(name, size: size, weight: weight)
    }
}

extension NSColor {
    /// Multiplies the color's own alpha (dark palette tokens carry alpha; replacing it would
    /// turn `white 11%` into a bright grey).
    func timelineAlpha(_ fraction: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * fraction)
    }
}

/// A plain container with top-left origin, like every timeline view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
