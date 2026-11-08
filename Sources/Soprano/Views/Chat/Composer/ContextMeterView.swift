import AppKit

/// How full a thread's context window is, as the composer meter and its card show it.
struct ContextMeterReading: Equatable {
    enum Level: Equatable {
        /// Under 70%.
        case normal
        /// 70% and more.
        case warning
        /// 90% and more.
        case critical
    }

    let usedTokens: Int
    let contextWindow: Int
    let fraction: Double

    /// nil when the usage or its window is unknown.
    init?(used: Int?, size: Int?) {
        guard let used, let size, size > 0 else { return nil }
        usedTokens = used
        contextWindow = size
        fraction = Double(used) / Double(size)
    }

    var level: Level {
        if fraction >= 0.9 { return .critical }
        if fraction >= 0.7 { return .warning }
        return .normal
    }

    /// Rounded percentage ("31").
    var percent: Int { Int((fraction * 100).rounded()) }

    /// `Context: 62.4k / 200k tokens (31%)`.
    var toolTip: String {
        "Context: \(Self.tokens(usedTokens)) / \(Self.tokens(contextWindow)) tokens (\(percent)%)"
    }

    /// `62.4k of 200k tokens used · 31%`.
    var summary: String {
        "\(Self.tokens(usedTokens)) of \(Self.tokens(contextWindow)) tokens used · \(percent)%"
    }

    /// 950, 62.4k, 200k, 1M, 1.5M.
    static func tokens(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", value)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        if count >= 1_000_000 { return scaled(Double(count) / 1_000_000, "M") }
        if count >= 1000 { return scaled(Double(count) / 1000, "k") }
        return String(count)
    }
}

/// The composer footer's context meter: a 16 pt ring in a 28 pt ghost button, a full muted track
/// under an arc in foreground 70% below 70%, warning from 70%, error from 90%. Click opens the
/// context card.
final class ContextMeterView: InteractiveView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private(set) var reading: ContextMeterReading?

    /// The card the meter opens is showing.
    var isOpen = false {
        didSet { applyPalette(palette) }
    }

    /// A compaction runs: the ring dims.
    var isCompacting = false {
        didSet { applyPalette(palette) }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        layer?.cornerRadius = Radius.lg
        for shape in [track, progress] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityRole(.button)
        update(nil)
    }

    func update(_ reading: ContextMeterReading?) {
        self.reading = reading
        isHidden = reading == nil
        let text = isCompacting ? "Compacting conversation…" : reading?.toolTip
        toolTip = text
        setAccessibilityLabel(text ?? "Context")
        progress.strokeEnd = CGFloat(min(max(reading?.fraction ?? 0, 0), 1))
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side: CGFloat = 16
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side).insetBy(dx: 1, dy: 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        // Clockwise from 12 o'clock in the layer's unflipped space.
        path.addArc(center: center, radius: rect.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, progress] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The full circle under the arc, so the ring reads as a meter rather than a spinner.
        track.strokeColor = palette.mutedForeground.withAlphaComponent(0.25).cgColor
        let tint: NSColor = switch reading?.level ?? .normal {
        case .normal: palette.foreground.withAlphaComponent(0.7)
        case .warning: palette.warning
        case .critical: palette.error
        }
        progress.strokeColor = tint.cgColor
        progress.opacity = isCompacting ? 0.45 : 1
        CATransaction.commit()
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// The meter's card: "Context window", a bar, `62.4k of 200k tokens used · 31%`, what compacting
/// does, and "Compact conversation".
final class ContextMeterCardContent: ComposerPopoverContent {
    private let title = NSTextField.label("Context window", size: Typography.rowSize, weight: .medium)
    private let barTrack = PaletteView()
    private let barFill = PaletteView()
    private var barWidth: NSLayoutConstraint?
    private let summary = NSTextField.label("", size: Typography.smallSize)
    private let hint = ComposerWrappingLabel.make(size: Typography.smallSize)
    private let button = TextButton("Compact conversation", symbol: "arrow.down.right.and.arrow.up.left", variant: .outline, size: .sm)
    private var reading: ContextMeterReading?
    private let onCompact: () -> Void

    static let width: CGFloat = 272

    init(onCompact: @escaping () -> Void) {
        self.onCompact = onCompact
        super.init(frame: .zero)
        hint.stringValue = "Compacting summarizes earlier messages to free space."
        barTrack.layer?.cornerRadius = 3
        barFill.layer?.cornerRadius = 3
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barTrack.addSubview(barFill)
        let buttonRow = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(button)
        let column = ComposerColumn([title, barTrack, summary, hint, buttonRow], spacing: 8, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        column.setSpacing(10, after: title)
        column.setSpacing(6, after: barTrack)
        column.setSpacing(4, after: summary)
        column.setSpacing(12, after: hint)
        addSubview(column)
        let fill = barFill.widthAnchor.constraint(equalToConstant: 0)
        barWidth = fill
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            barTrack.heightAnchor.constraint(equalToConstant: 6),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            fill,
            button.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
            button.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            button.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        ])
        hint.preferredMaxLayoutWidth = Self.width - 24
        button.onClick = { [weak self] in self?.onCompact() }
        applyPalette(palette)
    }

    /// Re-renders for the thread's latest usage and compaction state.
    func update(_ reading: ContextMeterReading?, canCompact: Bool, isCompacting: Bool) {
        self.reading = reading
        summary.stringValue = reading?.summary ?? "Context usage is not known yet."
        barWidth?.constant = (Self.width - 24) * CGFloat(min(max(reading?.fraction ?? 0, 0), 1))
        button.title = isCompacting ? "Compacting…" : "Compact conversation"
        button.setAccessibilityLabel(button.title)
        button.isEnabled = canCompact && !isCompacting
        applyPalette(palette)
        requestResize?()
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76), button.isEnabled {
            onCompact()
            return true
        }
        return super.handleKey(event)
    }

    override func applyPalette(_ palette: Palette) {
        title.textColor = palette.foreground
        summary.textColor = palette.mutedForeground
        hint.textColor = palette.mutedForeground
        barTrack.layer?.backgroundColor = palette.foreground.withAlphaComponent(0.1).cgColor
        let tint: NSColor = switch reading?.level ?? .normal {
        case .normal: palette.primary
        case .warning: palette.warning
        case .critical: palette.error
        }
        barFill.layer?.backgroundColor = tint.cgColor
    }
}
