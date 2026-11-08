import AppKit

// Soprano Agents' board surfaces (`Views/Statistics/StatisticsViews.swift`:
// the card, the headline tile, the breakdown card's header and notice) and its
// status pill, ported for the Automations page.

/// A board card: `rounded-xl border border-border/60 bg-card/40` (the settings group look) with
/// `p-4` content.
final class AutoUICardView: PaletteView {
    static let inset: CGFloat = 16

    init(content: NSView, inset: CGFloat = AutoUICardView.inset) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.xl
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.card.withAlphaComponent(0.4).cgColor
        layer?.borderColor = palette.border.withAlphaComponent(palette.border.alphaComponent * 0.6).cgColor
    }
}

/// A setting as a board tile: muted title, the value, an optional muted detail line, on a card
/// (`StatisticsTileView` with a text value).
final class AutoUITileView: PaletteView {
    init(title: String, value: NSView, detail: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = AutoUIThemedLabel(title, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
        var views: [NSView] = [titleLabel, value]
        if let detail, !detail.isEmpty {
            views.append(AutoUIThemedLabel(detail, size: Typography.smallSize) { $0.mutedForeground })
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(6, after: titleLabel)
        for view in views {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        let card = AutoUICardView(content: stack, inset: 14)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
    }

    /// A tile's value: 14 pt medium, wrapping, foreground (or muted for an unset value);
    /// `mono` for commands, cron and paths; `path` keeps one line, cut at the head.
    static func value(_ text: String, mono: Bool = false, muted: Bool = false, path: Bool = false) -> NSTextField {
        let label = AutoUIThemedLabel(text, size: Typography.bodySize, weight: .medium, wrapping: !path) {
            muted ? $0.mutedForeground : $0.foreground
        }
        if mono || path { label.font = Typography.mono(Typography.rowSize, weight: .medium) }
        if path { label.lineBreakMode = .byTruncatingHead }
        label.isSelectable = !path
        return label
    }
}

/// The header of a board card: the title (`text-sm font-semibold`) and a muted hint on its
/// baseline, padded so it lines up with rows inside an 8 pt card.
@MainActor
enum AutoUICardHeader {
    static func make(_ title: String, hint: String? = nil, inRowCard: Bool = true) -> NSStackView {
        let titleLabel = AutoUIThemedLabel(title, size: Typography.bodySize, weight: .semibold)
        var views: [NSView] = [titleLabel]
        if let hint, !hint.isEmpty {
            views.append(AutoUIThemedLabel(hint, size: Typography.smallSize) { $0.mutedForeground })
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        let pad: CGFloat = inRowCard ? 8 : 0
        row.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: 0, right: pad)
        return row
    }

    /// A titled card holding `body` (a wrapping text, a code block): `p-4`, the title 12 pt
    /// above it.
    static func card(_ title: String, hint: String? = nil, body: [NSView]) -> AutoUICardView {
        let header = make(title, hint: hint, inRowCard: false)
        let stack = NSStackView(views: [header] + body)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: header)
        for view in body {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return AutoUICardView(content: stack)
    }
}

/// A notice card: the message in the error color and an optional button on the right (the
/// Statistics board's failure notice).
@MainActor
enum AutoUINotice {
    static func make(title: String, message: String?, button: NSView?) -> AutoUICardView {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: Typography.ui(Typography.rowSize, weight: .semibold),
        ])
        if let message, !message.isEmpty {
            text.append(NSAttributedString(string: " \(message)", attributes: [.font: Typography.ui(Typography.rowSize)]))
        }
        let label = AutoUIThemedLabel("", size: Typography.rowSize, wrapping: true) { $0.errorForeground }
        label.attributedStringValue = text
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView(image: NSImage.symbol(Icon.circleAlert, size: 14) ?? NSImage())
        icon.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [icon, label]
        if let button {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let card = AutoUICardView(content: row, inset: 12)
        PaletteCenter.shared.addObserver(icon) { [weak icon] palette in icon?.contentTintColor = palette.errorForeground }
        icon.contentTintColor = PaletteCenter.shared.palette.errorForeground
        return card
    }
}

// MARK: - Status pills

/// Agents' status pill laid out from its leading edge: a 12.5 pt symbol and the word in
/// 12 pt tabular medium, both in the tone's color. `ShellStatusPill` supplies the content.
final class AutoUIPillView: PaletteView {
    let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let icon = NSImageView()
    private(set) var pill: ShellStatusPill?
    private var now = Date()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.tabular(Typography.smallSize, weight: .medium)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyPalette(palette)
    }

    convenience init(_ pill: ShellStatusPill, now: Date = Date()) {
        self.init(frame: .zero)
        configure(pill, now: now)
    }

    func configure(_ pill: ShellStatusPill?, now: Date = Date()) {
        self.pill = pill
        self.now = now
        icon.image = pill.map { NSImage.symbol($0.symbol, size: 12.5) } ?? nil
        label.stringValue = pill?.text(now: now) ?? ""
        setAccessibilityElement(pill != nil)
        setAccessibilityLabel(label.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyPalette(palette)
    }

    override var intrinsicContentSize: NSSize {
        guard pill != nil else { return NSSize(width: 0, height: 20) }
        // As `ShellStatusPillView`: 16 pt icon, 4 pt gap, the text; the label's
        // cell needs 4 pt more than its intrinsic width, 2 of them past the edge.
        return NSSize(width: 16 + 4 + ceil(label.intrinsicContentSize.width), height: 20)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 18, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        let color = pill.map { palette.color(for: $0.tone) } ?? palette.mutedForeground
        icon.contentTintColor = color
        label.textColor = color
    }
}

/// The pills of the Automations page: a run's status, and an automation's state (its live run,
/// else Paused, Failed after a failed last run, else Active).
@MainActor
enum AutomationPill {
    static func run(_ status: AutomationRun.Status, since: Date? = nil) -> ShellStatusPill {
        switch status {
        case .starting: ShellStatusPill(label: "Starting", symbol: Icon.circleDashed, tone: .working, since: nil)
        case .running: ShellStatusPill(label: "Running", symbol: Icon.circleDashed, tone: .working, since: since)
        case .needsInput: ShellStatusPill(label: "Input", symbol: Icon.messageQuestion, tone: .input, since: nil)
        case .completed: ShellStatusPill(label: "Done", symbol: Icon.circleCheck, tone: .done, since: nil)
        case .failed: ShellStatusPill(label: "Failed", symbol: Icon.circleAlert, tone: .failed, since: nil)
        case .skipped: ShellStatusPill(label: "Skipped", symbol: "minus.circle", tone: .muted, since: nil)
        }
    }

    static func state(of automation: Automation, lastRun: AutomationRun?) -> ShellStatusPill {
        if let lastRun, !lastRun.status.isFinal {
            return run(lastRun.status, since: lastRun.status == .running ? lastRun.startedAt : nil)
        }
        if !automation.enabled {
            return ShellStatusPill(label: "Paused", symbol: "pause.circle", tone: .muted, since: nil)
        }
        if lastRun?.status == .failed {
            return run(.failed)
        }
        return ShellStatusPill(label: "Active", symbol: Icon.alarm, tone: .done, since: nil)
    }
}
