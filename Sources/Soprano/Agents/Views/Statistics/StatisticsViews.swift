import AppKit
import SopranoAgentsCore

/// A board card: `rounded-xl border border-border/60 bg-card/40` (the settings group look) with
/// `p-4` content.
final class StatisticsCardView: PaletteView {
    static let inset: CGFloat = 16

    init(content: NSView, inset: CGFloat = StatisticsCardView.inset) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.xl
        layer?.borderWidth = 1
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

/// Segmented control: a muted `rounded-lg` track with the selected segment raised.
final class StatisticsSegmentedControl: PaletteView {
    var onSelect: ((Int) -> Void)?
    private var segments: [StatisticsSegment] = []

    var selectedIndex: Int {
        didSet {
            for (index, segment) in segments.enumerated() { segment.isSelected = index == selectedIndex }
        }
    }

    init(titles: [String], accessibilityLabels: [String]? = nil, selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (index, title) in titles.enumerated() {
            let segment = StatisticsSegment(title: title, accessibilityLabel: accessibilityLabels?[index] ?? title)
            segment.isSelected = index == selectedIndex
            segment.onClick = { [weak self] in
                guard let self, selectedIndex != index else { return }
                self.selectedIndex = index
                onSelect?(index)
            }
            segments.append(segment)
            stack.addArrangedSubview(segment)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(0.06).cgColor
    }
}

final class StatisticsSegment: InteractiveView {
    private let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)

    var isSelected = false {
        didSet { applyPalette(palette) }
    }

    init(title: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        label.stringValue = title
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isSelected ? palette.popover : isHovered ? palette.accent : .clear).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = palette.input.withAlphaComponent(palette.input.alphaComponent * 0.6).cgColor
        label.textColor = isSelected || isHovered ? palette.foreground : palette.mutedForeground
        alphaValue = isPressed ? 0.85 : 1
    }
}

/// A headline number: muted title, the value large, one muted detail line.
final class StatisticsTileView: PaletteView {
    init(title: String, value: String, detail: String) {
        super.init(frame: .zero)
        let titleLabel = ThemedLabel(title, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
        let valueLabel = ThemedLabel(value, size: 22, weight: .semibold)
        valueLabel.font = Typography.tabular(22, weight: .semibold)
        let detailLabel = ThemedLabel(detail, size: Typography.smallSize) { $0.mutedForeground }
        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(6, after: titleLabel)
        let card = StatisticsCardView(content: stack, inset: 14)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for label in [titleLabel, valueLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title): \(value), \(detail)")
    }
}

/// Colors of the stacked bar parts.
enum UsagePartColor {
    static func color(_ part: UsagePart, _ palette: Palette) -> NSColor {
        switch part {
        case .input: palette.info
        case .output: palette.primary
        case .cacheRead: palette.success
        case .cacheWrite: palette.warning
        }
    }

    /// Bottom to top.
    static let stackOrder: [UsagePart] = [.cacheRead, .cacheWrite, .input, .output]
}

/// The legend: a swatch and name per bar part.
final class UsageLegendView: PaletteView {
    private var swatches: [(UsagePart, CALayer)] = []

    init() {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for part in UsagePartColor.stackOrder.reversed() {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 2
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 8),
                swatch.heightAnchor.constraint(equalToConstant: 8),
            ])
            if let layer = swatch.layer { swatches.append((part, layer)) }
            let label = ThemedLabel(part.title, size: Typography.smallSize) { $0.mutedForeground }
            let item = NSStackView(views: [swatch, label])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 6
            stack.addArrangedSubview(item)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        for (part, layer) in swatches { layer.backgroundColor = UsagePartColor.color(part, palette).cgColor }
    }
}

/// Stacked bars per bucket (input, output, cache read, cache write) over three gridlines, with
/// value labels on the left and a few bucket labels below. Hovering a bar highlights its column
/// and reports its index.
final class UsageChartView: PaletteView {
    static let height: CGFloat = 200
    private static let axisWidth: CGFloat = 56
    private static let labelHeight: CGFloat = 18
    private static let topInset: CGFloat = 8

    var onHover: ((Int?) -> Void)?

    private var buckets: [UsageBucket] = []
    private var metric: UsageMetric = .cost
    private var unit: UsageBucketUnit = .day
    private var scaleMax: Double = 1
    private(set) var hoveredIndex: Int?

    private let highlight = CALayer()
    private var gridLines: [CALayer] = []
    private var bars: [CALayer] = []
    private var segments: [[(UsagePart, CALayer)]] = []
    private var valueLabels: [NSTextField] = []
    private var bucketLabels: [(index: Int, label: NSTextField)] = []
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(highlight)
        highlight.cornerRadius = Radius.sm
        for _ in 0..<3 {
            let line = CALayer()
            layer?.addSublayer(line)
            gridLines.append(line)
            let label = Self.axisLabel(alignment: .right)
            addSubview(label)
            valueLabels.append(label)
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        applyPalette(palette)
    }

    func configure(buckets: [UsageBucket], metric: UsageMetric, unit: UsageBucketUnit) {
        self.buckets = buckets
        self.metric = metric
        self.unit = unit
        hoveredIndex = nil
        let peak = buckets.map { $0.totals.value(metric) }.max() ?? 0
        scaleMax = Self.niceCeiling(peak)
        for (index, label) in valueLabels.enumerated() {
            label.stringValue = StatisticsFormat.axisValue(scaleMax * Double(index) / 2, metric)
        }

        for bar in bars { bar.removeFromSuperlayer() }
        bars = []
        segments = []
        for _ in buckets {
            let bar = CALayer()
            bar.cornerRadius = 2
            bar.masksToBounds = true
            var parts: [(UsagePart, CALayer)] = []
            for part in UsagePartColor.stackOrder {
                let segment = CALayer()
                bar.addSublayer(segment)
                parts.append((part, segment))
            }
            layer?.addSublayer(bar)
            bars.append(bar)
            segments.append(parts)
        }

        for (_, label) in bucketLabels { label.removeFromSuperview() }
        bucketLabels = []
        let stride = max(1, Int((Double(buckets.count) / 7).rounded(.up)))
        var index = buckets.count - 1
        while index >= 0 {
            let label = Self.axisLabel(alignment: .center)
            label.stringValue = StatisticsFormat.axisLabel(buckets[index].start, unit: unit)
            addSubview(label)
            bucketLabels.append((index, label))
            index -= stride
        }
        applyPalette(palette)
        needsLayout = true
    }

    /// The smallest 1, 2, 2.5 or 5 × 10ⁿ at or above `value` (1 for nothing).
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1, 2, 2.5, 5, 10] where step * magnitude >= value {
            return step * magnitude
        }
        return 10 * magnitude
    }

    private var plotRect: NSRect {
        NSRect(
            x: Self.axisWidth,
            y: Self.topInset,
            width: max(0, bounds.width - Self.axisWidth),
            height: max(0, bounds.height - Self.topInset - Self.labelHeight - 6)
        )
    }

    private var slotWidth: CGFloat {
        buckets.isEmpty ? 0 : plotRect.width / CGFloat(buckets.count)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let plot = plotRect
        for (index, line) in gridLines.enumerated() {
            let y = plot.maxY - plot.height * CGFloat(index) / 2
            line.frame = NSRect(x: plot.minX, y: (y - 0.5).rounded(), width: plot.width, height: 1)
            valueLabels[index].frame = NSRect(x: 0, y: y - 8, width: Self.axisWidth - 10, height: 16)
        }
        let slot = slotWidth
        let barWidth = max(2, min(28, (slot * 0.66).rounded()))
        for (index, bar) in bars.enumerated() {
            let totals = buckets[index].totals
            let total = totals.value(metric)
            let height = scaleMax > 0 ? plot.height * CGFloat(total / scaleMax) : 0
            let x = (plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2).rounded()
            bar.frame = NSRect(x: x, y: plot.maxY - height, width: barWidth, height: height)
            // Bottom to top inside the bar (the layer follows the flipped view: y grows down).
            var top = height
            for (part, segment) in segments[index] {
                let value = totals.value(part, metric)
                let segmentHeight = total > 0 ? height * CGFloat(value / total) : 0
                top -= segmentHeight
                segment.frame = NSRect(x: 0, y: top, width: barWidth, height: segmentHeight)
            }
        }
        for (index, label) in bucketLabels {
            let width: CGFloat = 64
            let center = plot.minX + slot * (CGFloat(index) + 0.5)
            let x = min(max(center - width / 2, plot.minX - 8), bounds.width - width)
            label.frame = NSRect(x: x, y: plot.maxY + 6, width: width, height: Self.labelHeight)
        }
        layoutHighlight()
    }

    private func layoutHighlight() {
        guard let index = hoveredIndex, index < buckets.count else {
            highlight.isHidden = true
            return
        }
        let plot = plotRect
        let slot = slotWidth
        highlight.isHidden = false
        highlight.frame = NSRect(x: plot.minX + slot * CGFloat(index), y: plot.minY, width: slot, height: plot.height)
    }

    override func applyPalette(_ palette: Palette) {
        highlight.backgroundColor = palette.accent.cgColor
        for line in gridLines {
            line.backgroundColor = palette.border.withAlphaComponent(palette.border.alphaComponent * 0.6).cgColor
        }
        for parts in segments {
            for (part, segment) in parts { segment.backgroundColor = UsagePartColor.color(part, palette).cgColor }
        }
        for label in valueLabels { label.textColor = palette.mutedForeground }
        for (_, label) in bucketLabels { label.textColor = palette.mutedForeground }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// The bucket under `point`, nil outside the plot.
    func index(at point: NSPoint) -> Int? {
        let plot = plotRect
        guard plot.contains(point), slotWidth > 0 else { return nil }
        let index = Int((point.x - plot.minX) / slotWidth)
        return buckets.indices.contains(index) ? index : nil
    }

    func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutHighlight()
        CATransaction.commit()
        onHover?(index)
    }

    private static func axisLabel(alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField.label("", size: Typography.tinySize)
        label.font = Typography.tabular(Typography.tinySize)
        label.alignment = alignment
        return label
    }
}

/// One breakdown line: optional color dot, title and muted subtitle, a share bar with its
/// percentage, extra columns, and the value on the right. Clickable rows (models) highlight on
/// hover and when selected.
final class StatisticsBreakdownRow: InteractiveView {
    struct Column {
        var text: String
        var width: CGFloat
        var muted = true
    }

    static let height: CGFloat = 34

    private let colorIndex: Int?
    private let dot = CALayer()
    private let share: Double
    private let track = CALayer()
    private let fill = CALayer()
    private let barWidth: CGFloat
    private let barHost = NSView()
    private let clickable: Bool

    var isSelected = false {
        didSet { applyPalette(palette) }
    }

    init(
        title: String,
        subtitle: String? = nil,
        colorIndex: Int? = nil,
        share: Double,
        barWidth: CGFloat,
        columns: [Column],
        value: String,
        valueMuted: Bool = false,
        clickable: Bool = false
    ) {
        self.colorIndex = colorIndex
        self.share = min(max(share, 0), 1)
        self.barWidth = barWidth
        self.clickable = clickable
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md

        var leading: [NSView] = []
        if colorIndex != nil {
            let dotHost = NSView()
            dotHost.wantsLayer = true
            dotHost.layer?.addSublayer(dot)
            dot.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
            dot.cornerRadius = 4
            dotHost.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dotHost.widthAnchor.constraint(equalToConstant: 8),
                dotHost.heightAnchor.constraint(equalToConstant: 8),
            ])
            leading.append(dotHost)
        }
        let titleLabel = ThemedLabel(title, size: Typography.rowSize, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        leading.append(titleLabel)
        if let subtitle {
            let subtitleLabel = ThemedLabel(subtitle, size: Typography.smallSize) { $0.mutedForeground }
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            leading.append(subtitleLabel)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        leading.append(spacer)

        barHost.wantsLayer = true
        barHost.layer?.addSublayer(track)
        barHost.layer?.addSublayer(fill)
        track.cornerRadius = 2
        fill.cornerRadius = 2
        barHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            barHost.widthAnchor.constraint(equalToConstant: barWidth),
            barHost.heightAnchor.constraint(equalToConstant: 4),
        ])
        var trailing: [NSView] = barWidth > 0 ? [barHost] : []
        let shareLabel = Self.columnLabel(StatisticsFormat.percent(self.share), width: 44, muted: true)
        trailing.append(shareLabel)
        for column in columns {
            trailing.append(Self.columnLabel(column.text, width: column.width, muted: column.muted))
        }
        let valueLabel = Self.columnLabel(value, width: 76, muted: valueMuted)
        valueLabel.font = Typography.tabular(Typography.rowSize, weight: .medium)
        trailing.append(valueLabel)

        let stack = NSStackView(views: leading + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        if let titleIndex = leading.firstIndex(of: titleLabel), titleIndex > 0 {
            stack.setCustomSpacing(10, after: leading[titleIndex - 1])
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityRole(clickable ? .button : .row)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: 0, width: barWidth, height: 4)
        fill.frame = NSRect(x: 0, y: 0, width: max(share > 0 ? 2 : 0, barWidth * CGFloat(share)), height: 4)
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        let active = isSelected || (clickable && isHovered)
        layer?.backgroundColor = (active ? palette.accent : .clear).cgColor
        let tint = colorIndex.map { palette.projectIconColors[$0 % palette.projectIconColors.count] } ?? palette.primary
        dot.backgroundColor = tint.cgColor
        track.backgroundColor = palette.foreground.withAlphaComponent(0.08).cgColor
        fill.backgroundColor = tint.cgColor
        alphaValue = isPressed ? 0.85 : 1
    }

    private static func columnLabel(_ text: String, width: CGFloat, muted: Bool) -> NSTextField {
        let label = ThemedLabel(text, size: Typography.smallSize) { muted ? $0.mutedForeground : $0.foreground }
        label.font = Typography.tabular(Typography.smallSize)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }
}
