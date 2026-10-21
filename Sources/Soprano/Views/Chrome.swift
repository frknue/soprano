import AppKit

// Soprano's chrome design language, "Folio": paper and ink, a serif voice for
// titles, one 1 px hairline between regions, and one sienna pencil mark
// wherever the keyboard is. Every chrome surface draws from these tokens and
// components so the look holds together in Paper, Ink and every third-party
// palette. Spec: docs/design/2026-10-21-calm-family/b/direction.md.
//
// This file depends only on AppKit, Theme.swift and NSColor+Hex.swift, so the
// sibling apps can vendor it unchanged.

// MARK: - Metrics

enum Chrome {
    /// Every border and rule is one hairline.
    static let hairline: CGFloat = 1
    /// The sienna rule under a focused pane or region header.
    static let focusMarkWidth: CGFloat = 2
    /// The frame around an attention pane.
    static let attentionFrame: CGFloat = 2

    /// The 2×14 pencil tick sits `tickInset` inside the selection pill.
    static let tickInset: CGFloat = 4
    static let tickWidth: CGFloat = 2
    static let tickHeight: CGFloat = 14
    /// Horizontal inset of a selection pill from its list's edges.
    static let pillInset: CGFloat = 4

    static let statusMark: CGFloat = 8
    static let statusMarkSmall: CGFloat = 6
    static let ringStroke: CGFloat = 2

    /// Buttons, popups and the settings keycap field.
    static let controlHeight: CGFloat = 24
    static let controlHeightLarge: CGFloat = 28
    static let fieldHeight: CGFloat = 26
    static let keycapHeight: CGFloat = 18
    static let keycapHeightSmall: CGFloat = 16
    static let chipHeight: CGFloat = 18
    static let modeChipHeight: CGFloat = 18
    static let iconButtonSize: CGFloat = 24
    static let switchSize = NSSize(width: 26, height: 16)

    /// macOS radii. Tiled panes and splitters stay square (0).
    enum Radius {
        /// Floating panels: palette, launcher, switcher.
        static let panel: CGFloat = 12
        /// Popovers, toasts, HUD, dialogs, windows.
        static let popover: CGFloat = 10
        /// Settings cards, tiles.
        static let card: CGFloat = 8
        /// Buttons, fields, popups, selection pills, tabs.
        static let control: CGFloat = 6
        /// Keycaps, chips, ref pills.
        static let cap: CGFloat = 4
    }

    /// The 4-pt spacing scale.
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s48: CGFloat = 48
        /// Horizontal inset inside bars.
        static let bar: CGFloat = 12
        /// Inset inside panels.
        static let panel: CGFloat = 16
        /// Page gutter.
        static let page: CGFloat = 24
    }
}

// MARK: - Type

/// Chrome typography. SF Pro for everything you scan or type, New York
/// (`SystemDesign.serif`) for titles, headlines, figures and empty states at
/// 15 pt and above, SF Mono for paths, SHAs, code and diffs. Nothing below 11.
enum ChromeFont {
    // Serif roles (New York).

    /// Hero: About, Welcome. 30 / 400.
    static var title: NSFont { serif(size: 30) }
    /// Screen title: Settings, Dashboard. 22 / 400.
    static var screen: NSFont { serif(size: 22) }
    /// Headline: dialog title, commit subject, detail title. 17 / 500.
    static var headline: NSFont { serif(size: 17, weight: .medium) }
    /// Empty state. 17 / 400 italic, muted.
    static var empty: NSFont { serif(size: 17, italic: true) }
    /// Dashboard figures. 26 / 400, tabular.
    static var figure: NSFont { serif(size: 26, tabular: true) }

    // Sans roles (SF Pro).

    /// Launcher query (SF Pro Display at this size). 20 / 400.
    static var query: NSFont { sans(size: 20) }
    /// ⌘P search field. 15 / 400.
    static var paletteQuery: NSFont { sans(size: 15) }
    /// Launcher, palette and table rows. 13 / 400.
    static var row: NSFont { sans(size: 13) }
    /// Chrome labels. 12 / 400.
    static var label: NSFont { sans(size: 12) }
    /// Selected tab, window row, ink buttons. 12 / 500.
    static var labelStrong: NSFont { sans(size: 12, weight: .medium) }
    /// Secondary text and hints, usually muted. 11 / 400.
    static var meta: NSFont { sans(size: 11) }
    /// UPPERCASE section heads (`ChromeText.eyebrow`). 11 / 600.
    static var eyebrow: NSFont { sans(size: 11, weight: .semibold) }
    /// UPPERCASE status labels (`ChromeText.status`). 11 / 600.
    static var status: NSFont { sans(size: 11, weight: .semibold) }
    /// Keycap legends. 11 / 500, tabular digits.
    static var keycap: NSFont { sans(size: 11, weight: .medium, tabular: true) }
    /// Aggregate badge counts (`● 3`). 11 / 500, tabular.
    static var badge: NSFont { sans(size: 11, weight: .medium, tabular: true) }
    /// Row counts, timers and the uptime readout. 11 / 400, tabular.
    static var count: NSFont { sans(size: 11, tabular: true) }

    // Mono roles (SF Mono).

    /// Paths, code, diff. 12 / 400.
    static var mono: NSFont { monospaced(size: 12) }
    /// SHAs, dates, line numbers. 11 / 400.
    static var monoSmall: NSFont { monospaced(size: 11) }

    // Building blocks.

    /// SF Pro at any size. `tabular` gives monospaced digits.
    static func sans(
        size: CGFloat = 12,
        weight: NSFont.Weight = .regular,
        tabular: Bool = false
    ) -> NSFont {
        tabular
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    /// SF Mono at any size.
    static func monospaced(size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// New York at any size; keep it at 15 pt or more.
    static func serif(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false,
        tabular: Bool = false
    ) -> NSFont {
        serifFonts.font(for: SerifKey(size: size, weight: weight.rawValue, italic: italic, tabular: tabular)) {
            makeSerif(size: size, weight: weight, italic: italic, tabular: tabular)
        }
    }

    private static let serifFonts = SerifFontCache()

    private static func makeSerif(
        size: CGFloat,
        weight: NSFont.Weight,
        italic: Bool,
        tabular: Bool
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic {
            descriptor = descriptor.withSymbolicTraits(.italic)
        }
        if tabular {
            descriptor = descriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
        }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

private struct SerifKey: Hashable {
    let size: CGFloat
    let weight: CGFloat
    let italic: Bool
    let tabular: Bool
}

/// Lock-protected rather than main-actor isolated because fonts are also
/// requested from nonisolated text builders.
private final class SerifFontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fonts: [SerifKey: NSFont] = [:]

    func font(for key: SerifKey, make: () -> NSFont) -> NSFont {
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

enum ChromeText {
    /// Letter spacing of eyebrows, in points.
    static let eyebrowTracking: CGFloat = 0.6
    /// Letter spacing of status labels and mode chips, in points.
    static let statusTracking: CGFloat = 0.4

    /// A styled string in any role.
    static func attributed(
        _ text: String,
        font: NSFont,
        color: NSColor,
        tracking: CGFloat = 0,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if tracking != 0 {
            attributes[.kern] = tracking
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// An UPPERCASE section head: 11 Semibold, +0.6 tracking. Pass
    /// `uppercased: false` for a verbatim segment (a query, a file name) and
    /// concatenate.
    static func eyebrow(
        _ text: String,
        color: NSColor,
        uppercased: Bool = true,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        attributed(
            uppercased ? text.uppercased() : text,
            font: ChromeFont.eyebrow,
            color: color,
            tracking: eyebrowTracking,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }

    /// An UPPERCASE status label in its status color: 11 Semibold, +0.4.
    static func status(
        _ text: String,
        color: NSColor,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        attributed(
            text.uppercased(),
            font: ChromeFont.status,
            color: color,
            tracking: statusTracking,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }
}

extension NSTextField {
    /// Sets the label's text in a chrome role, keeping the field's own
    /// alignment and line break mode. `stringValue` stays `text`.
    func setChromeText(
        _ text: String,
        font: NSFont = ChromeFont.label,
        color: NSColor,
        tracking: CGFloat = 0
    ) {
        attributedStringValue = ChromeText.attributed(
            text,
            font: font,
            color: color,
            tracking: tracking,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }

    /// Sets an eyebrow. `stringValue` becomes the uppercased text.
    func setEyebrowText(_ text: String, color: NSColor) {
        attributedStringValue = ChromeText.eyebrow(
            text,
            color: color,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }

    /// Sets a status label. `stringValue` becomes the uppercased text.
    func setStatusText(_ text: String, color: NSColor) {
        attributedStringValue = ChromeText.status(
            text,
            color: color,
            alignment: alignment,
            lineBreakMode: lineBreakMode
        )
    }
}

// MARK: - Rules

/// A divider: one hairline in `borderSubtle` between regions, or a thicker
/// mark such as the 2 px focus rule. Stack views never stretch its thickness.
final class ChromeRuleView: NSView {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis
    let thickness: CGFloat
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(axis: Axis, thickness: CGFloat = Chrome.hairline, color: NSColor = .separatorColor) {
        self.axis = axis
        self.thickness = thickness
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
            NSSize(width: NSView.noIntrinsicMetric, height: thickness)
        case .vertical:
            NSSize(width: thickness, height: NSView.noIntrinsicMetric)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        switch axis {
        case .horizontal:
            NSRect(
                x: bounds.minX,
                y: floor(bounds.midY - thickness / 2),
                width: bounds.width,
                height: thickness
            ).fill()
        case .vertical:
            NSRect(
                x: floor(bounds.midX - thickness / 2),
                y: bounds.minY,
                width: thickness,
                height: bounds.height
            ).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Status

/// The agent and pane states and how Folio marks them: ring = nothing
/// happening, dot = activity or your turn, diamond = failure.
enum ChromeStatus: CaseIterable {
    case starting
    case working
    case running
    case ready
    case needsInput
    case error
    case stopped
    case idle

    var shape: ChromeStatusMark.Shape {
        switch self {
        case .starting, .ready, .stopped: .ring
        case .working, .running, .needsInput: .dot
        case .error: .diamond
        case .idle: .idle
        }
    }

    /// The UPPERCASE label word. Idle shells carry no label.
    var label: String {
        switch self {
        case .starting: "STARTING"
        case .working: "WORKING"
        case .running: "RUNNING"
        case .ready: "READY"
        case .needsInput: "NEEDS INPUT"
        case .error: "ERROR"
        case .stopped: "STOPPED"
        case .idle: ""
        }
    }

    func color(in colors: ThemeColors) -> NSColor {
        switch self {
        case .starting, .needsInput: colors.yellow
        case .working: colors.success
        case .running: colors.runningCommand
        case .ready: colors.blue
        case .error: colors.danger
        case .stopped: colors.gray
        case .idle: colors.idleMark
        }
    }

    /// Pane-header wash; only NEEDS INPUT and ERROR have one.
    func headerWash(in colors: ThemeColors) -> NSColor? {
        switch self {
        case .needsInput: colors.needsInputWash
        case .error: colors.errorWash
        default: nil
        }
    }
}

/// A flat 8 px status mark: dot, 2 px ring, or diamond (a 6 px square turned
/// 45°). Idle is a 6 px dot. No glow.
final class ChromeStatusMark: NSView {
    enum Shape {
        case dot
        case ring
        case diamond
        case idle
    }

    var shape: Shape {
        didSet { needsDisplay = true }
    }
    var color: NSColor {
        didSet { needsDisplay = true }
    }
    let size: CGFloat

    init(shape: Shape = .dot, color: NSColor = .systemGray, size: CGFloat = Chrome.statusMark) {
        self.shape = shape
        self.color = color
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `status` in `colors`.
    func set(status: ChromeStatus, colors: ThemeColors) {
        shape = status.shape
        color = status.color(in: colors)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        color.set()
        switch shape {
        case .dot:
            NSBezierPath(ovalIn: square(side: size, center: center)).fill()
        case .idle:
            NSBezierPath(ovalIn: square(side: size * 0.75, center: center)).fill()
        case .ring:
            let ring = NSBezierPath(ovalIn: square(side: size - Chrome.ringStroke, center: center))
            ring.lineWidth = Chrome.ringStroke
            ring.stroke()
        case .diamond:
            let half = size * 0.5625
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: center.x, y: center.y + half))
            diamond.line(to: NSPoint(x: center.x + half, y: center.y))
            diamond.line(to: NSPoint(x: center.x, y: center.y - half))
            diamond.line(to: NSPoint(x: center.x - half, y: center.y))
            diamond.close()
            diamond.fill()
        }
    }

    private func square(side: CGFloat, center: NSPoint) -> NSRect {
        NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Hover tracking

/// Hover state shared by the chrome controls. Swapping cached tab contents or
/// hiding a view can skip the mouse-exit event, so both reset it.
@MainActor
private final class HoverTracker {
    private(set) var isHovered = false
    private var area: NSTrackingArea?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func update(in view: NSView, options: NSTrackingArea.Options) {
        if let area {
            view.removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, options],
            owner: view
        )
        view.addTrackingArea(area)
        self.area = area
    }

    func set(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        onChange()
    }
}

// MARK: - Buttons

/// A 24 pt, 6 pt-radius push button.
///
/// - `standard`: raised fill, `borderStrong` edge; hover fills `hover`.
/// - `ink`: the primary action, filled with ink (`textPrimary`).
/// - `danger`: a destructive action, filled with `danger`.
/// - `text`: borderless; hover fills `hover`.
///
/// An optional trailing keycap (`Done esc`, `Commit ⌘↵`) is drawn inside.
final class ChromeButton: NSButton {
    enum Kind {
        case standard
        case ink
        case danger
        case text
    }

    static let horizontalPadding: CGFloat = 10
    private static let keycapGap: CGFloat = 6
    private static let keycapHeight: CGFloat = 16

    var kind: Kind {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// Trailing keycap legend, e.g. `esc` or `⌘↵`.
    var keycap: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private(set) var theme: AppTheme
    private lazy var hover = HoverTracker { [weak self] in self?.needsDisplay = true }

    init(
        title: String,
        theme: AppTheme,
        kind: Kind = .standard,
        keycap: String? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.theme = theme
        self.kind = kind
        self.keycap = keycap
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

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        var width = ceil(label(color: .labelColor).size().width) + Self.horizontalPadding * 2
        if let keycap {
            width += Self.keycapGap + keycapWidth(keycap)
        }
        return NSSize(width: width, height: Chrome.controlHeight)
    }

    private struct Palette {
        var fill: NSColor?
        var edge: NSColor?
        var text: NSColor
        var keycapEdge: NSColor
        var keycapFill: NSColor?
        var keycapText: NSColor
    }

    private var palette: Palette {
        let colors = theme.colors
        let isPressed = isEnabled && isHighlighted
        let isHot = isEnabled && hover.isHovered
        switch kind {
        case .standard:
            guard isEnabled else {
                return Palette(fill: nil, edge: colors.borderSubtle, text: colors.textMuted,
                               keycapEdge: colors.borderSubtle, keycapFill: nil, keycapText: colors.textMuted)
            }
            let fill = isPressed ? colors.bgOverlay : (isHot ? colors.hover : colors.raised)
            return Palette(fill: fill, edge: colors.borderStrong, text: colors.textPrimary,
                           keycapEdge: colors.keycapEdge, keycapFill: colors.keycapFill,
                           keycapText: colors.textPrimary)
        case .ink:
            guard isEnabled else {
                return Palette(fill: colors.bgOverlay, edge: colors.bgOverlay, text: colors.textMuted,
                               keycapEdge: colors.textMuted.withAlphaComponent(0.35), keycapFill: nil,
                               keycapText: colors.textMuted)
            }
            let fill = isPressed || isHot ? colors.inkButtonPressed : colors.inkButtonFill
            return Palette(fill: fill, edge: fill, text: colors.inkButtonLabel,
                           keycapEdge: colors.inkButtonLabel.withAlphaComponent(0.35), keycapFill: nil,
                           keycapText: colors.inkButtonLabel)
        case .danger:
            guard isEnabled else {
                return Palette(fill: colors.bgOverlay, edge: colors.bgOverlay, text: colors.textMuted,
                               keycapEdge: colors.textMuted.withAlphaComponent(0.40), keycapFill: nil,
                               keycapText: colors.textMuted)
            }
            let fill = isPressed || isHot ? colors.dangerButtonHover : colors.dangerButtonFill
            return Palette(fill: fill, edge: fill, text: colors.dangerButtonLabel,
                           keycapEdge: colors.dangerButtonLabel.withAlphaComponent(0.40), keycapFill: nil,
                           keycapText: colors.dangerButtonLabel)
        case .text:
            let fill: NSColor? = isPressed ? colors.bgOverlay : (isHot ? colors.hover : nil)
            return Palette(fill: fill, edge: nil, text: isEnabled ? colors.textPrimary : colors.textMuted,
                           keycapEdge: colors.keycapEdge, keycapFill: colors.keycapFill,
                           keycapText: colors.textMuted)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = palette
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        if let fill = palette.fill {
            fill.setFill()
            shape.fill()
        }
        if let edge = palette.edge {
            edge.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }

        let string = label(color: palette.text)
        let size = string.size()
        var contentWidth = size.width
        if let keycap {
            contentWidth += Self.keycapGap + keycapWidth(keycap)
        }
        let originX = floor((bounds.width - contentWidth) / 2)
        string.draw(at: NSPoint(x: originX, y: floor((bounds.height - size.height) / 2)))

        if let keycap {
            let capRect = NSRect(
                x: originX + size.width + Self.keycapGap,
                y: floor((bounds.height - Self.keycapHeight) / 2),
                width: keycapWidth(keycap),
                height: Self.keycapHeight
            )
            ChromeKeycapView.drawCap(
                keycap,
                in: capRect,
                fill: palette.keycapFill,
                edge: palette.keycapEdge,
                text: palette.keycapText,
                font: ChromeFont.keycap,
                radius: Chrome.Radius.cap
            )
        }
    }

    private func keycapWidth(_ legend: String) -> CGFloat {
        ChromeKeycapView.capWidth(legend, font: ChromeFont.keycap, height: Self.keycapHeight, padding: 4)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        hover.set(false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover.set(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(in: self, options: .activeInKeyWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.set(true)
    }

    override func mouseExited(with event: NSEvent) {
        hover.set(false)
    }

    private func label(color: NSColor) -> NSAttributedString {
        let font = kind == .ink || kind == .danger ? ChromeFont.labelStrong : ChromeFont.label
        return ChromeText.attributed(title, font: font, color: color, lineBreakMode: .byClipping)
    }
}

/// Borderless SF Symbol button (24 pt box, 13 pt Regular glyph) for headers,
/// toolbars and footers: muted at rest, ink with a `hover` fill under the
/// pointer, and a raised pill while `isToggledOn`. Never accent.
final class ChromeIconButton: NSButton {
    static let defaultSize: CGFloat = Chrome.iconButtonSize

    /// A toggled-on icon (a showing panel, an active filter) sits on a raised
    /// pill with a `borderSubtle` ring.
    var isToggledOn = false {
        didSet { refresh() }
    }
    private var theme: AppTheme?
    private lazy var hover = HoverTracker { [weak self] in self?.refresh() }

    init(
        symbolName: String,
        accessibilityLabel: String,
        pointSize: CGFloat = 13,
        size: CGFloat = ChromeIconButton.defaultSize,
        target: AnyObject?,
        action: Selector?
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control
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
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        setAccessibilityLabel(accessibilityLabel)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            refresh()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        hover.set(false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover.set(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(in: self, options: .activeInActiveApp)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.set(true)
    }

    override func mouseExited(with event: NSEvent) {
        hover.set(false)
    }

    private func refresh() {
        guard let colors = theme?.colors else { return }
        let isHot = hover.isHovered && isEnabled
        contentTintColor = isHot || isToggledOn ? colors.textPrimary : colors.textMuted
        let fill: NSColor? = isToggledOn ? colors.raised : (isHot ? colors.hover : nil)
        layer?.backgroundColor = fill?.cgColor
        layer?.borderWidth = isToggledOn ? Chrome.hairline : 0
        layer?.borderColor = colors.borderSubtle.cgColor
    }
}

// MARK: - Headings

/// A section heading: an UPPERCASE eyebrow, muted, with no trailing rule.
/// `stringValue` of `label` is the uppercased title.
final class ChromeEyebrowView: NSView {
    let label = NSTextField(labelWithString: "")
    private var theme: AppTheme

    var title: String {
        didSet { refresh() }
    }

    init(title: String, theme: AppTheme) {
        self.title = title
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    private func refresh() {
        label.setEyebrowText(title, color: theme.colors.textMuted)
    }
}

// MARK: - Keycaps

/// One keycap. Rule K1: one cap per chord (`⌘1`, `⇧⌘P`, `⌃A`); a prefix
/// sequence is a `ChromeKeycapGroupView` of separate caps; letter legends are
/// uppercase, named keys (`esc`) lowercase. Callers pass legends pre-joined.
final class ChromeKeycapView: NSView {
    enum Style {
        /// 18 pt cap.
        case standard
        /// 16 pt cap for hint rows and inside buttons.
        case small
        /// 24 pt, 6 pt-radius cap used as the settings keycap control.
        case field
    }

    enum Tone {
        /// Ink legend on a `borderStrong` edge.
        case primary
        /// Muted legend (hint rows).
        case muted
        /// Accent legend and edge: the Prefix cap and ⌃-jump digits.
        case accent
    }

    var legend: String {
        didSet { invalidateAndRedraw() }
    }
    var style: Style {
        didSet { invalidateAndRedraw() }
    }
    var tone: Tone {
        didSet { needsDisplay = true }
    }
    private var theme: AppTheme

    init(legend: String, theme: AppTheme, style: Style = .standard, tone: Tone = .primary) {
        self.legend = legend
        self.theme = theme
        self.style = style
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(legend)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    private var metrics: (height: CGFloat, padding: CGFloat, minWidth: CGFloat, radius: CGFloat, font: NSFont) {
        switch style {
        case .standard:
            (Chrome.keycapHeight, 5, Chrome.keycapHeight, Chrome.Radius.cap, ChromeFont.keycap)
        case .small:
            (Chrome.keycapHeightSmall, 4, Chrome.keycapHeightSmall, Chrome.Radius.cap, ChromeFont.keycap)
        case .field:
            (Chrome.controlHeight, 10, 84, Chrome.Radius.control, ChromeFont.sans(size: 12, weight: .medium))
        }
    }

    override var intrinsicContentSize: NSSize {
        let metrics = metrics
        let width = Self.capWidth(legend, font: metrics.font, height: metrics.minWidth, padding: metrics.padding)
        return NSSize(width: width, height: metrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let metrics = metrics
        let edge: NSColor
        let text: NSColor
        switch tone {
        case .primary:
            edge = colors.keycapEdge
            text = colors.textPrimary
        case .muted:
            edge = colors.keycapEdge
            text = colors.textMuted
        case .accent:
            edge = colors.accent
            text = colors.accent
        }
        Self.drawCap(
            legend,
            in: bounds,
            fill: colors.keycapFill,
            edge: edge,
            text: text,
            font: metrics.font,
            radius: metrics.radius
        )
    }

    /// Width of a cap holding `legend`: legend plus padding, never narrower
    /// than `height` so single glyphs stay square.
    static func capWidth(_ legend: String, font: NSFont, height: CGFloat, padding: CGFloat) -> CGFloat {
        let textWidth = ceil((legend as NSString).size(withAttributes: [.font: font]).width)
        return max(height, textWidth + padding * 2)
    }

    /// Draws one cap; shared with `ChromeButton`'s trailing keycap.
    static func drawCap(
        _ legend: String,
        in rect: NSRect,
        fill: NSColor?,
        edge: NSColor,
        text: NSColor,
        font: NSFont,
        radius: CGFloat
    ) {
        let shape = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        if let fill {
            fill.setFill()
            shape.fill()
        }
        edge.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()

        // Center the cap height, not the line box: the box carries descender
        // space, so a centered box draws ⌘, letters and digits high.
        let string = ChromeText.attributed(legend, font: font, color: text, lineBreakMode: .byClipping)
        let size = string.size()
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let originY = flipped
            ? rect.midY + font.capHeight / 2 - font.ascender
            : rect.midY - font.capHeight / 2 + font.descender
        string.draw(at: NSPoint(
            x: rect.minX + floor((rect.width - size.width) / 2),
            y: round(originY)
        ))
    }

    private func invalidateAndRedraw() {
        setAccessibilityLabel(legend)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// A K1 sequence: one cap per step with a 3 pt gap (`⌃A` then `P`).
final class ChromeKeycapGroupView: NSStackView {
    var caps: [String] {
        didSet { rebuild() }
    }
    var style: ChromeKeycapView.Style {
        didSet { rebuild() }
    }
    var tone: ChromeKeycapView.Tone {
        didSet { rebuild() }
    }
    private var theme: AppTheme

    init(
        caps: [String],
        theme: AppTheme,
        style: ChromeKeycapView.Style = .standard,
        tone: ChromeKeycapView.Tone = .primary
    ) {
        self.caps = caps
        self.theme = theme
        self.style = style
        self.tone = tone
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        for case let cap as ChromeKeycapView in arrangedSubviews {
            cap.apply(theme: theme)
        }
    }

    private func rebuild() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for legend in caps {
            addArrangedSubview(ChromeKeycapView(legend: legend, theme: theme, style: style, tone: tone))
        }
        setAccessibilityLabel(caps.joined(separator: " then "))
    }
}

// MARK: - Chips

/// The keybinding mode chip in the status bar: NORMAL is muted text with no
/// border; PREFIX and COPY are outlined in accent; SELECT in blue.
final class ChromeModeChip: NSView {
    enum Mode {
        case normal
        case prefix
        case copy
        case select
    }

    private let label = NSTextField(labelWithString: "")
    private var theme: AppTheme
    private(set) var mode: Mode = .normal
    private(set) var text: String = "Normal"
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.cap
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailing = trailingAnchor.constraint(equalTo: label.trailingAnchor)
        NSLayoutConstraint.activate([
            leading,
            trailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Chrome.modeChipHeight),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The label's `stringValue` (uppercased `text`), for tests and
    /// accessibility.
    var displayedText: String { label.stringValue }

    func set(mode: Mode, text: String) {
        self.mode = mode
        self.text = text
        refresh()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        let tint: NSColor? = switch mode {
        case .normal: nil
        case .prefix, .copy: colors.accent
        case .select: colors.blue
        }
        label.setStatusText(text, color: tint ?? colors.textMuted)
        let padding: CGFloat = tint == nil ? 0 : 6
        leading.constant = padding
        trailing.constant = padding
        layer?.borderWidth = tint == nil ? 0 : Chrome.hairline
        layer?.borderColor = tint?.cgColor
        setAccessibilityLabel(text)
    }
}

/// A small 18 pt label chip (`settings.json`, `Minimized`): `bgOverlay`
/// fill, or an outline.
final class ChromeChip: NSView {
    enum Style {
        case filled
        case outline
    }

    private let label = NSTextField(labelWithString: "")
    private var theme: AppTheme
    var text: String {
        didSet { refresh() }
    }
    var style: Style {
        didSet { refresh() }
    }

    init(text: String, theme: AppTheme, style: Style = .filled) {
        self.text = text
        self.theme = theme
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.cap
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Chrome.chipHeight),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        label.setChromeText(text, font: ChromeFont.sans(size: 11, weight: .medium), color: colors.textMuted)
        switch style {
        case .filled:
            layer?.backgroundColor = colors.bgOverlay.cgColor
            layer?.borderWidth = 0
        case .outline:
            layer?.backgroundColor = nil
            layer?.borderWidth = Chrome.hairline
            layer?.borderColor = colors.borderStrong.cgColor
        }
    }
}

// MARK: - Selection

/// List and tab selection idioms, drawn into any row or tab rect.
enum ChromeSelectionPill {
    enum Style: Equatable {
        case none
        /// Pointer over the row: `hover` pill.
        case hover
        /// Selected row in the focused list: `selection` pill plus the
        /// pencil tick `tickInset` inside its leading edge.
        case selected
        /// Selected row in an unfocused list: `selectionMuted` pill, no tick.
        case selectedUnfocused
        /// A row that wants you: full-bleed `attentionRowWash` and an
        /// attention tick, no pill, so it never reads as selected.
        case attention
        /// Selected tab or settings nav item: raised 6 pt pill with a
        /// `borderSubtle` edge.
        case raisedTab
    }

    /// Draws `style` for a row occupying `bounds`. Pills inset `inset`
    /// horizontally; the attention wash is full-bleed. Selection never moves
    /// row content.
    static func draw(
        _ style: Style,
        in bounds: NSRect,
        colors: ThemeColors,
        inset: CGFloat = Chrome.pillInset
    ) {
        let pill = bounds.insetBy(dx: inset, dy: 0)
        switch style {
        case .none:
            return
        case .hover:
            fillPill(pill, color: colors.hover)
        case .selected:
            fillPill(pill, color: colors.selection)
            drawTick(x: pill.minX + Chrome.tickInset, in: bounds, color: colors.pencilTick)
        case .selectedUnfocused:
            fillPill(pill, color: colors.selectionMuted)
        case .attention:
            colors.attentionRowWash.setFill()
            bounds.fill(using: .sourceOver)
            drawTick(x: bounds.minX + Chrome.tickInset, in: bounds, color: colors.attention)
        case .raisedTab:
            let shape = NSBezierPath(
                roundedRect: pill.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Chrome.Radius.control,
                yRadius: Chrome.Radius.control
            )
            colors.raised.setFill()
            shape.fill()
            colors.borderSubtle.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }
    }

    private static func fillPill(_ rect: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        ).fill()
    }

    private static func drawTick(x: CGFloat, in bounds: NSRect, color: NSColor) {
        let tick = NSRect(
            x: x,
            y: floor(bounds.midY - Chrome.tickHeight / 2),
            width: Chrome.tickWidth,
            height: Chrome.tickHeight
        )
        color.setFill()
        NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1).fill()
    }
}

/// A row background that draws a `ChromeSelectionPill` style. Put it behind a
/// row's content (or use `ChromeSelectionPill.draw` from a row's own
/// `draw(_:)`).
final class ChromeRowBackgroundView: NSView {
    var style: ChromeSelectionPill.Style = .none {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }
    var inset: CGFloat = Chrome.pillInset {
        didSet { needsDisplay = true }
    }
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeSelectionPill.draw(style, in: bounds, colors: theme.colors, inset: inset)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Switch

/// A 26×16 switch. Off: `bgOverlay` track with a `borderStrong` edge and a
/// `switchKnobOff` knob. On: ink track, `bgRaised` knob. Space toggles it
/// when focused.
final class ChromeSwitch: NSControl {
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isOn)
        }
    }

    /// `NSButton`-style state so checkbox call sites migrate unchanged.
    var state: NSControl.StateValue {
        get { isOn ? .on : .off }
        set { isOn = newValue == .on }
    }

    private var theme: AppTheme

    init(isOn: Bool = false, theme: AppTheme, target: AnyObject? = nil, action: Selector? = nil) {
        self.isOn = isOn
        self.theme = theme
        super.init(frame: NSRect(origin: .zero, size: Chrome.switchSize))
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(isOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { Chrome.switchSize }
    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let size = Chrome.switchSize
        let track = NSRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        let trackPath = NSBezierPath(roundedRect: track, xRadius: size.height / 2, yRadius: size.height / 2)
        (isOn ? colors.inkButtonFill : colors.bgOverlay).setFill()
        trackPath.fill()
        if !isOn {
            let edge = NSBezierPath(
                roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
                xRadius: size.height / 2 - 0.5,
                yRadius: size.height / 2 - 0.5
            )
            colors.borderStrong.setStroke()
            edge.lineWidth = Chrome.hairline
            edge.stroke()
        }

        let knobSide: CGFloat = 12
        let knob = NSRect(
            x: track.minX + (isOn ? size.width - knobSide - 2 : 2),
            y: track.minY + 2,
            width: knobSide,
            height: knobSide
        )
        let knobPath = NSBezierPath(ovalIn: knob)
        (isOn ? colors.inkButtonLabel : colors.switchKnobOff).setFill()
        knobPath.fill()
        if !isOn {
            colors.borderStrong.setStroke()
            knobPath.lineWidth = Chrome.hairline
            knobPath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    private func toggle() {
        isOn.toggle()
        sendAction(action, to: target)
    }
}

// MARK: - Checkbox

/// A 14 pt checkbox. Checked is an ink fill with a tick; the `quiet` style
/// for dense tables keeps the outline and draws an ink tick only.
final class ChromeCheckbox: NSControl {
    enum Style {
        case standard
        case quiet
    }

    static let side: CGFloat = 14

    var isChecked: Bool = false {
        didSet {
            guard isChecked != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isChecked)
        }
    }

    /// `NSButton`-style state so checkbox call sites migrate unchanged.
    var state: NSControl.StateValue {
        get { isChecked ? .on : .off }
        set { isChecked = newValue == .on }
    }

    var style: Style {
        didSet { needsDisplay = true }
    }
    private var theme: AppTheme

    init(
        isChecked: Bool = false,
        theme: AppTheme,
        style: Style = .standard,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.isChecked = isChecked
        self.theme = theme
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(isChecked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let box = NSRect(
            x: floor((bounds.width - Self.side) / 2),
            y: floor((bounds.height - Self.side) / 2),
            width: Self.side,
            height: Self.side
        )
        let shape = NSBezierPath(
            roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.cap,
            yRadius: Chrome.Radius.cap
        )
        let filled = isChecked && style == .standard
        (filled ? colors.inkButtonFill : colors.raised).setFill()
        shape.fill()
        (filled ? colors.inkButtonFill : colors.borderStrong).setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()

        guard isChecked else { return }
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + 3.5, y: box.midY + 0.5))
        tick.line(to: NSPoint(x: box.minX + 6, y: box.midY - 2.5))
        tick.line(to: NSPoint(x: box.maxX - 3.5, y: box.midY + 3))
        tick.lineWidth = 2
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        (filled ? colors.inkButtonLabel : colors.textPrimary).setStroke()
        tick.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    private func toggle() {
        isChecked.toggle()
        sendAction(action, to: target)
    }
}

// MARK: - Fields

/// The surface behind a text field or search field: raised fill, 6 pt
/// radius, a `borderStrong` edge that darkens to `fieldFocusEdge` while
/// focused (the caret carries the accent, never the border). Embed a field
/// styled with `ChromeFieldView.styleEmbedded(_:colors:)`.
final class ChromeFieldView: NSView {
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
        }
    }
    var isInvalid = false {
        didSet {
            guard isInvalid != oldValue else { return }
            needsDisplay = true
        }
    }
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        colors.raised.setFill()
        shape.fill()
        let edge = isInvalid ? colors.danger : (isFocused ? colors.fieldFocusEdge : colors.borderStrong)
        edge.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
    }

    /// Makes `field` a borderless, backgroundless SF Pro field that sits on a
    /// `ChromeFieldView`.
    @MainActor
    static func styleEmbedded(_ field: NSTextField, colors: ThemeColors, font: NSFont = ChromeFont.label) {
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = colors.textPrimary
    }

    /// Gives an active field editor the accent caret and the theme's text
    /// selection. Call from `controlTextDidBeginEditing` or after
    /// `makeFirstResponder`.
    @MainActor
    static func styleEditor(of field: NSTextField, colors: ThemeColors) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = colors.caret
        editor.selectedTextAttributes = [.backgroundColor: colors.textSelection]
    }
}

// MARK: - Surfaces

enum ChromeSurface {
    /// Styles `layer` as the unfocused-pane veil: `bgPanel` multiplied on
    /// Paper, black @ 18 % on dark themes. Never put it on attention panes.
    static func applyVeil(to layer: CALayer, colors: ThemeColors) {
        layer.backgroundColor = colors.unfocusedVeil.cgColor
        layer.compositingFilter = colors.unfocusedVeilCompositingFilter
    }

    /// A floating surface (palette, popover, toast): raised fill, rounded,
    /// with the elevation shadow and its contact ring.
    static func applyFloating(
        to layer: CALayer,
        colors: ThemeColors,
        radius: CGFloat = Chrome.Radius.panel,
        shadow: ThemeShadow
    ) {
        layer.backgroundColor = colors.raised.cgColor
        layer.cornerRadius = radius
        shadow.apply(to: layer)
    }
}
