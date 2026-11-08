import AppKit

// Soprano Agents' sidebar and panel widgets, ported onto the shared
// `AgentsStyle` layer for Soprano's own chrome (sidebars, tab rows, headers).
// Every color comes from `PaletteCenter.shared.palette`, fonts from
// `Typography`, radii from `Radius`.

extension NSColor {
    /// Tailwind's `color/NN` (Agents' `alphaScaled`): scales the token's own
    /// alpha, so translucent tokens stay translucent.
    func shellScaled(by factor: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * factor)
    }
}

// MARK: - Project identity

/// Agents' project monogram: two glyphs and a color derived from the name.
enum ShellProjectIdentity {
    static func monogram(_ name: String) -> String {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        guard let firstWord = words.first, let first = firstWord.first else { return "PR" }
        let second = firstWord.dropFirst().first(where: \.isNumber)
            ?? (words.count > 1 ? words.last?.first : firstWord.last)
            ?? first
        return String(String([first, second]).uppercased().prefix(2))
    }

    /// Index into `Palette.projectIconColors` (`(index * 31 + codePoint) % count` over the lowercased name).
    static func colorIndex(_ name: String, count: Int) -> Int {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = normalized.isEmpty ? "project" : normalized.lowercased()
        var index = 0
        for scalar in seed.unicodeScalars {
            index = (index * 31 + Int(scalar.value)) % count
        }
        return index
    }
}

/// The project favicon stand-in: two glyphs on a 14 % tint of the project
/// color, `rounded-[25%]`, mono 8.25 bold in a 16 pt tile.
final class ShellMonogramView: PaletteView {
    var projectName: String? {
        didSet {
            guard projectName != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let projectName else { return }
        let colors = palette.projectIconColors
        let color = colors[ShellProjectIdentity.colorIndex(projectName, count: colors.count)]
        let side = min(bounds.width, bounds.height)
        let tile = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        color.shellScaled(by: 0.14).setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.25, yRadius: side * 0.25).fill()

        let text = ShellProjectIdentity.monogram(projectName)
        let scale = side / 16
        let font = NSFont.monospacedSystemFont(ofSize: 8.25 * scale, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        let targetWidth = (text.count == 1 ? 6 : 12) * scale
        let horizontal = min(1, targetWidth / max(size.width, 1))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: tile.midX, yBy: tile.minY + 10.8 * scale)
        transform.scaleX(by: horizontal, yBy: 1)
        transform.concat()
        string.draw(at: NSPoint(x: -size.width / 2, y: -font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Durations

enum ShellDuration {
    /// Live working duration: `Ns` under a minute, `Nm` under an hour, else `Hh Mm`.
    static func compact(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Relative time: "now", "Nm", "Nh", "Nd".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Status pills

/// When each agent entered the status it shows, so pills can count a live
/// "Working 2m" and idle rows a relative time. Soprano's model has no
/// status timestamp, so the chrome records the first moment it sees one.
@MainActor
final class ShellStatusClock {
    static let shared = ShellStatusClock()
    private var entries: [String: (status: AgentStatus, since: Date)] = [:]

    /// When `agent` entered its current status (as far as the chrome saw).
    func since(_ agent: AgentInstance, now: Date = Date()) -> Date {
        if let entry = entries[agent.id], entry.status == agent.status {
            return entry.since
        }
        // A fresh agent counts from its start; any later change from now.
        let since = entries[agent.id] == nil && agent.status != .idle ? (agent.startedAt ?? now) : now
        entries[agent.id] = (agent.status, since)
        return since
    }
}

/// Agents' sidebar status pill: Working (info, live duration), Approval
/// (warning), Input (indigo), Failed (error), Done (success); Soprano adds
/// Starting, Running (a shell running a command) and Stopped.
struct ShellStatusPill: Equatable {
    let label: String
    let symbol: String
    let tone: ThreadStatusTone
    /// Live duration counts from here ("Working 12s").
    let since: Date?

    /// "Working 12s", "Approval".
    func text(now: Date) -> String {
        guard let since else { return label }
        return "\(label) \(ShellDuration.compact(now.timeIntervalSince(since)))"
    }

    static let running = ShellStatusPill(label: "Running", symbol: Icon.terminal, tone: .working, since: nil)

    /// The pill for an agent; nil for an idle agent (rows show a relative
    /// time there).
    @MainActor
    static func of(_ agent: AgentInstance, now: Date = Date()) -> ShellStatusPill? {
        of(
            status: agent.status,
            waitingReason: agent.waitingReason,
            workingSince: agent.status == .running ? ShellStatusClock.shared.since(agent, now: now) : nil
        )
    }

    /// The pill for a status: a finished turn reads Done, an approval prompt
    /// Approval, a question (or a wait of unknown kind) Input.
    static func of(status: AgentStatus, waitingReason: AgentWaitingReason?, workingSince: Date?) -> ShellStatusPill? {
        switch status {
        case .running:
            ShellStatusPill(label: "Working", symbol: Icon.circleDashed, tone: .working, since: workingSince)
        case .starting:
            ShellStatusPill(label: "Starting", symbol: Icon.circleDashed, tone: .working, since: nil)
        case .waiting:
            switch waitingReason {
            case .approval: ShellStatusPill(label: "Approval", symbol: Icon.shieldQuestion, tone: .approval, since: nil)
            case .question, nil: ShellStatusPill(label: "Input", symbol: Icon.messageQuestion, tone: .input, since: nil)
            case .turnEnded: ShellStatusPill(label: "Done", symbol: Icon.circleCheck, tone: .done, since: nil)
            }
        case .error:
            ShellStatusPill(label: "Failed", symbol: Icon.circleAlert, tone: .failed, since: nil)
        case .stopped:
            ShellStatusPill(label: "Stopped", symbol: Icon.circleStop, tone: .muted, since: nil)
        case .idle:
            nil
        }
    }

    /// The pill for a pane's active tab: its agent's, else Running while a
    /// command runs in any of its tabs.
    @MainActor
    static func of(agent: AgentInstance?, runsCommand: Bool, now: Date = Date()) -> ShellStatusPill? {
        if let agent { return of(agent, now: now) }
        return runsCommand ? .running : nil
    }
}

/// Icon and tinted label of a status pill (12.5 pt symbol, 12 pt tabular
/// medium label), or a muted relative time. The label is public so owners
/// can give it an identifier.
final class ShellStatusPillView: PaletteView {
    let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let icon = NSImageView()
    private(set) var pill: ShellStatusPill?
    private var relativeDate: Date?
    private var now = Date()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.tabular(Typography.smallSize, weight: .medium)
        label.alignment = .right
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(label)
        applyPalette(palette)
    }

    /// Shows `pill`, or with none the time since `relativeTo` (or nothing).
    func configure(_ pill: ShellStatusPill?, relativeTo date: Date? = nil, now: Date = Date()) {
        self.pill = pill
        relativeDate = pill == nil ? date : nil
        self.now = now
        icon.image = pill.map { NSImage.symbol($0.symbol, size: 12.5) } ?? nil
        icon.isHidden = pill == nil
        refreshText()
        applyPalette(palette)
    }

    func refreshTime(_ now: Date) {
        self.now = now
        refreshText()
    }

    var hasLiveTime: Bool { pill?.since != nil || relativeDate != nil }

    private func refreshText() {
        let text = pill?.text(now: now) ?? relativeDate.map { ShellDuration.relative($0, now: now) } ?? ""
        guard label.stringValue != text else { return }
        label.stringValue = text
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    var isEmpty: Bool { label.stringValue.isEmpty }

    override var intrinsicContentSize: NSSize {
        guard !label.stringValue.isEmpty else { return NSSize(width: 0, height: 20) }
        let text = ceil(label.intrinsicContentSize.width)
        return NSSize(width: (icon.isHidden ? 0 : 16 + 4) + text, height: 20)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let width = ceil(size.width) + 4
        label.frame = NSRect(x: bounds.maxX + 2 - width, y: (bounds.height - size.height) / 2, width: width, height: size.height)
        icon.frame = NSRect(x: label.frame.minX + 2 - 4 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func applyPalette(_ palette: Palette) {
        let color = pill.map { palette.color(for: $0.tone) } ?? palette.secondaryLabel
        icon.contentTintColor = color
        label.textColor = color
        label.font = pill == nil ? Typography.tabular(Typography.smallSize) : Typography.tabular(Typography.smallSize, weight: .medium)
    }
}

// MARK: - Buttons

/// Agents' ghost icon button as an `NSButton`, so it keeps AppKit's target /
/// action, keyboard access and accessibility: a square SF Symbol with a
/// rounded hover fill. `.ghost` fills with `accent` (title bars, panels);
/// `.sidebar` with `sidebarRowHover` and a softer resting tint
/// (`SidebarIconButton`).
final class ShellGhostButton: NSButton {
    enum Variant {
        case ghost
        case sidebar
        /// Agents' round send button: a `foreground` disc with a
        /// `background` glyph, faded while disabled.
        case primary
    }

    let variant: Variant
    private let side: CGFloat
    private let symbolSize: CGFloat
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false

    var isOn = false {
        didSet { applyPalette() }
    }

    /// Tint at rest; nil = the variant's muted tint.
    var restingTint: NSColor? {
        didSet { applyPalette() }
    }

    override var isEnabled: Bool {
        didSet { applyPalette() }
    }

    init(
        symbol: String,
        label: String,
        size: CGFloat = Metrics.titlebarControlSize,
        symbolSize: CGFloat = 14,
        weight: NSFont.Weight = .regular,
        variant: Variant = .ghost,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.variant = variant
        side = size
        self.symbolSize = symbolSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = variant == .primary ? size / 2 : Radius.lg
        image = NSImage.symbol(symbol, size: symbolSize, weight: weight)
        toolTip = label
        setAccessibilityLabel(label)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyPalette() }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSymbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) {
        image = NSImage.symbol(name, size: size ?? symbolSize, weight: weight)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func applyPalette() {
        let palette = PaletteCenter.shared.palette
        let active = isEnabled && (isHovered || isOn)
        let fill: NSColor
        let tint: NSColor
        switch variant {
        case .ghost:
            fill = active ? palette.accent : .clear
            tint = !isEnabled ? palette.mutedForeground.shellScaled(by: 0.5)
                : active ? palette.foreground : (restingTint ?? palette.mutedForeground)
        case .sidebar:
            fill = active ? palette.sidebarRowHover : .clear
            tint = !isEnabled ? palette.sidebarMutedForeground.shellScaled(by: 0.5)
                : active ? palette.sidebarForeground : (restingTint ?? palette.sidebarMutedForeground.shellScaled(by: 0.8))
        case .primary:
            fill = !isEnabled ? palette.foreground.shellScaled(by: 0.2)
                : isHovered ? palette.foreground.shellScaled(by: 0.85) : palette.foreground
            tint = isEnabled ? palette.background : palette.background.shellScaled(by: 0.8)
        }
        layer?.backgroundColor = fill.cgColor
        contentTintColor = tint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyPalette()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyPalette()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isHovered {
            isHovered = false
            applyPalette()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// For the harness and tests: hover without a mouse.
    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        applyPalette()
    }
}

// MARK: - Row surface

/// The rounded fill behind a sidebar row (Agents' card surface): the open
/// row in `sidebarRowActive` (ringed in light mode), `sidebarRowSelected`
/// while another window holds the keyboard, `sidebarRowHover` under the
/// pointer. Inset `horizontalInset` from the row's edges.
final class ShellRowSurfaceView: NSView {
    enum Style: Equatable {
        case none
        case hover
        case selected
        case selectedUnfocused
    }

    var style: Style = .none {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }

    var horizontalInset: CGFloat = ShellSidebarMetrics.contentInset {
        didSet { needsDisplay = true }
    }

    var verticalInset: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let fill: NSColor? = switch style {
        case .none: nil
        case .hover: palette.sidebarRowHover
        case .selected: palette.sidebarRowActive
        case .selectedUnfocused: palette.sidebarRowSelected
        }
        guard let fill else { return }
        let rect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        let path = NSBezierPath(roundedRect: rect, xRadius: Radius.md, yRadius: Radius.md)
        fill.setFill()
        path.fill()
        if style == .selected, !palette.isDark {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.md, yRadius: Radius.md)
            ring.lineWidth = 1
            palette.sidebarBorder.shellScaled(by: 0.7).setStroke()
            ring.stroke()
        }
    }
}

/// Agents' sidebar geometry.
enum ShellSidebarMetrics {
    /// `--sidebar-content-inset`: list padding left and right.
    static let contentInset: CGFloat = 8
    /// `--sidebar-row-content-inset`: row padding left and right.
    static let rowInset: CGFloat = 10
    /// Where row content starts.
    static var contentLeft: CGFloat { contentInset + rowInset }
}

// MARK: - Jump hint

/// Agents' `JumpHintBadge`: a "⌃3" pill (mono 10 medium, 20 pt, round, hairline
/// edge) at a row's right edge while ⌃ is held. Soprano's longer pane hints
/// read as several caps ("⌃⇧Z Q").
final class ShellJumpHintBadge: PaletteView {
    private let label = NSTextField.label("", size: 10)

    var caps: [String] = [] {
        didSet {
            guard caps != oldValue else { return }
            label.stringValue = caps.joined(separator: " ")
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.mono(10, weight: .medium)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        addSubview(label)
        applyPalette(palette)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 4 + 12, height: 20)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 6, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.shellScaled(by: 0.95).cgColor
        layer?.borderColor = palette.border.shellScaled(by: 0.8).cgColor
        label.textColor = palette.foreground
    }
}

// MARK: - Tabs

/// Agents' right-panel tab look (`h-6 rounded-md`, active `bg-accent`, hover
/// `bg-accent/60`), shared by Soprano's tab rows.
enum ShellTabStyle {
    static let height: CGFloat = 24

    @MainActor
    static func fill(isActive: Bool, isHovered: Bool) -> NSColor? {
        let palette = PaletteCenter.shared.palette
        if isActive { return palette.accent }
        if isHovered { return palette.accent.shellScaled(by: 0.6) }
        return nil
    }

    @MainActor
    static func textColor(isActive: Bool, isHovered: Bool) -> NSColor {
        let palette = PaletteCenter.shared.palette
        return isActive || isHovered ? palette.foreground : palette.mutedForeground
    }

    @MainActor
    static func draw(isActive: Bool, isHovered: Bool, in rect: NSRect) {
        guard let fill = fill(isActive: isActive, isHovered: isHovered) else { return }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Radius.md, yRadius: Radius.md).fill()
    }
}

// MARK: - Title bar

/// Rows that sit in the window's title bar strip: room for the traffic
/// lights, and window dragging on their empty space.
@MainActor
enum ShellTitlebar {
    /// How far `view`'s content must stay from its leading edge so it clears
    /// the traffic lights; zero when they are not over the view.
    static func trafficLightInset(for view: NSView) -> CGFloat {
        guard let window = view.window,
              window.styleMask.contains(.titled),
              !window.styleMask.contains(.fullScreen),
              let zoom = window.standardWindowButton(.zoomButton),
              !zoom.isHiddenOrHasHiddenAncestor
        else { return 0 }
        let buttons = zoom.convert(zoom.bounds, to: nil)
        let mine = view.convert(view.bounds, to: nil)
        guard mine.minX < buttons.maxX, mine.maxY > buttons.minY, mine.minY < buttons.maxY else { return 0 }
        return max(0, buttons.maxX + 10 - mine.minX)
    }

    /// Height of the title bar strip over `view` (0 without a title bar).
    static func stripHeight(for view: NSView) -> CGFloat {
        view.safeAreaInsets.top
    }

    /// A click on empty title-bar space: double-click does what the user
    /// chose in System Settings (zoom, minimize or nothing), a drag moves
    /// the window.
    static func handleMouseDown(_ event: NSEvent, in view: NSView) {
        guard let window = view.window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// Empty space in a row that sits in the title bar strip (a tab strip's
/// document view): clicks move or zoom the window like the title bar.
final class ShellTitlebarDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        ShellTitlebar.handleMouseDown(event, in: self)
    }
}
