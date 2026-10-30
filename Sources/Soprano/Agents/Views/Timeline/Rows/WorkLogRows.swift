import AppKit
import SopranoAgentsCore

// MARK: - Shimmer

/// Live tool shine: the label in `secondary-label` with a 4.5rem window of
/// `foreground` text sweeping across it every 2.2 s. The window's resting frame covers the whole
/// label, so without the animation (Reduce Motion, offscreen renders) the label simply shows in
/// the highlight color.
final class ShimmerLabel: NSView {
    private let base = NSTextField.timelineLabel()
    private let sweep = NSView()
    private let highlight = NSTextField.timelineLabel()
    private var animatedWidth: CGFloat = -1

    var isShimmering = false {
        didSet {
            sweep.isHidden = !isShimmering
            animatedWidth = -1
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(base)
        addSubview(sweep)
        sweep.wantsLayer = true
        sweep.layer?.masksToBounds = true
        sweep.addSubview(highlight)
        sweep.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func set(_ text: String, font: NSFont, color: NSColor, highlightColor: NSColor) {
        for field in [base, highlight] {
            field.font = font
            field.stringValue = text
        }
        base.textColor = color
        highlight.textColor = highlightColor
        animatedWidth = -1
        needsLayout = true
    }

    var textWidth: CGFloat { base.textFitWidth }

    override func layout() {
        super.layout()
        let height = base.lineHeight
        let width = min(textWidth, bounds.width)
        let y = (bounds.height - height) / 2
        base.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        sweep.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        highlight.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        guard isShimmering, !Motion.reduceMotion, width != animatedWidth else { return }
        animatedWidth = width
        startAnimation(width: width)
    }

    private func startAnimation(width: CGFloat) {
        guard let windowLayer = sweep.layer, let highlightLayer = highlight.layer else { return }
        windowLayer.removeAnimation(forKey: "shine")
        highlightLayer.removeAnimation(forKey: "shine")
        let sweepWidth: CGFloat = 72
        let duration = 2.2
        let windowSize = CABasicAnimation(keyPath: "bounds.size.width")
        windowSize.fromValue = sweepWidth
        windowSize.toValue = sweepWidth
        let windowMove = CABasicAnimation(keyPath: "position.x")
        windowMove.fromValue = -sweepWidth / 2
        windowMove.toValue = width + sweepWidth / 2
        let windowGroup = CAAnimationGroup()
        windowGroup.animations = [windowSize, windowMove]
        windowGroup.duration = duration
        windowGroup.repeatCount = .infinity
        windowLayer.anchorPoint = CGPoint(x: 0.5, y: windowLayer.anchorPoint.y)
        windowLayer.add(windowGroup, forKey: "shine")

        // The highlight text moves the other way so it stays over the base text.
        let center = highlightLayer.position.x
        let counter = CABasicAnimation(keyPath: "position.x")
        counter.fromValue = center + sweepWidth
        counter.toValue = center - width
        counter.duration = duration
        counter.repeatCount = .infinity
        highlightLayer.add(counter, forKey: "shine")
    }
}

// MARK: - Work log line

/// A work-log line: a 24 pt line with a 16 pt icon in a 24 pt column, the label
/// (`secondary-label`, truncating), an optional detail, then trailing note / failure mark /
/// hover timestamp / chevron.
final class WorkLogLineView: NSView {
    static let height: CGFloat = 24

    let icon = TimelineIconView()
    let label = ShimmerLabel()
    let detail = NSTextField.timelineLabel()
    let note = NSTextField.timelineLabel("", size: Typography.smallSize)
    let failMark = TimelineIconView(symbol: TimelineIcon.circleX, size: 10)
    let time = NSTextField.timelineLabel("", size: Typography.smallSize)
    let chevron = TimelineIconView(symbol: Icon.chevronRight, size: 10)
    var showsChevron = true
    var chevronSlot = true
    var showsTime = false
    var chevronAfterLabel = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, label, detail, note, failMark, time, chevron] as [NSView] { addSubview(view) }
        detail.lineBreakMode = .byTruncatingTail
        time.alignment = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func layoutLine(width: CGFloat) {
        let height = Self.height
        icon.frame = NSRect(x: 2 + 4, y: (height - 16) / 2, width: 16, height: 16)
        var right = width - 2
        if chevronSlot, !chevronAfterLabel {
            chevron.isHidden = !showsChevron
            chevron.frame = NSRect(x: right - 16, y: (height - 16) / 2, width: 16, height: 16)
            right -= 16 + 6
        } else if !chevronAfterLabel {
            chevron.isHidden = true
        }
        time.isHidden = !showsTime || time.stringValue.isEmpty
        if !time.isHidden {
            let timeWidth = time.textFitWidth
            time.frame = NSRect(x: right - timeWidth, y: (height - 16) / 2, width: timeWidth, height: 16)
            right -= timeWidth + 6
        }
        if !failMark.isHidden {
            failMark.frame = NSRect(x: right - 12, y: (height - 12) / 2, width: 12, height: 12)
            right -= 12 + 6
        }
        if !note.stringValue.isEmpty {
            note.isHidden = false
            let noteWidth = min(note.textFitWidth, max(0, (right - 30) / 2))
            note.frame = NSRect(x: right - noteWidth, y: (height - 16) / 2, width: noteWidth, height: 16)
            right -= noteWidth + 6
        } else {
            note.isHidden = true
        }
        let x: CGFloat = 2 + 24 + 6
        var available = max(0, right - x)
        if chevronAfterLabel { available -= 18 }
        let labelWidth = min(label.textWidth, available)
        label.frame = NSRect(x: x, y: 0, width: labelWidth, height: height)
        var after = x + labelWidth
        if chevronAfterLabel {
            chevron.isHidden = !showsChevron
            chevron.frame = NSRect(x: after + 4, y: (height - 14) / 2, width: 14, height: 14)
            after += 18
        }
        if !detail.stringValue.isEmpty, available - labelWidth > 24 {
            detail.isHidden = false
            let detailHeight = detail.lineHeight
            detail.frame = NSRect(x: after + 6, y: (height - detailHeight) / 2, width: right - after - 6, height: detailHeight)
        } else {
            detail.isHidden = true
        }
    }

    func applyColors(palette: Palette, labelColor: NSColor, failed: Bool) {
        icon.contentTintColor = failed ? palette.error.timelineAlpha(0.85) : palette.mutedForeground
        detail.textColor = palette.mutedForeground.timelineAlpha(0.85)
        note.textColor = palette.mutedForeground
        failMark.contentTintColor = palette.error.timelineAlpha(0.85)
        time.textColor = palette.mutedForeground
        chevron.contentTintColor = palette.mutedForeground.timelineAlpha(0.7)
    }
}

/// Base for clickable work-log rows: a click on the header line toggles.
class ClickableRowView: TimelineRowView {
    var headerRect: NSRect = .zero
    var onToggle: (() -> Void)?
    private var pressed = false

    override var tracksHover: Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = headerRect.contains(convert(event.locationInWindow, from: nil)) && onToggle != nil
        if !pressed { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, headerRect.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseUp(with: event)
            return
        }
        onToggle?()
    }

    override func resetCursorRects() {
        if onToggle != nil { addCursorRect(headerRect, cursor: .pointingHand) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Fold / working

/// "Worked for 3m 12s ›" at the top of a finished turn (`border-b border-border/60 pb-2 pt-1`).
final class FoldRowView: ClickableRowView {
    private let label = NSTextField.timelineLabel("", size: Typography.bodySize)
    private let chevron = TimelineIconView(symbol: Icon.chevronRight, size: 11)
    private let time = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let rule = NSView()
    private var model: FoldRowModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [label, chevron, time, rule] as [NSView] { addSubview(view) }
        label.font = Typography.tabular(Typography.bodySize)
        rule.wantsLayer = true
        onToggle = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineToggleFold(turnID: model.turnID)
        }
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .fold(model) = row.content else { return }
        self.model = model
        label.stringValue = model.label
        chevron.setSymbol(model.expanded ? Icon.chevronDown : Icon.chevronRight, size: 11, weight: .medium)
        time.stringValue = TimelineFormat.timestamp(model.date)
        time.toolTip = TimelineFormat.tooltip(model.date)
        setAccessibilityRole(.button)
        setAccessibilityLabel(model.label)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        let lineHeight: CGFloat = 23
        let labelWidth = label.textFitWidth
        label.frame = NSRect(x: 4, y: 4 + (lineHeight - label.lineHeight) / 2, width: labelWidth, height: label.lineHeight)
        chevron.frame = NSRect(x: label.frame.maxX + 4, y: 4 + (lineHeight - 14) / 2, width: 14, height: 14)
        let timeWidth = time.textFitWidth
        time.frame = NSRect(x: width - 2 - timeWidth, y: 4 + (lineHeight - 16) / 2, width: timeWidth, height: 16)
        time.isHidden = !isHovered
        headerRect = NSRect(x: 0, y: 0, width: chevron.frame.maxX + 4, height: 4 + lineHeight + 8)
        rule.frame = NSRect(x: 0, y: 4 + lineHeight + 8, width: width, height: 1)
        window?.invalidateCursorRects(for: self)
        return 4 + lineHeight + 8 + 1
    }

    override func hoverChanged() {
        time.isHidden = !isHovered
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = isHovered ? palette.foreground : palette.mutedForeground
        chevron.contentTintColor = isHovered ? palette.foreground : palette.mutedForeground
        time.textColor = palette.mutedForeground
        rule.layer?.backgroundColor = palette.border.timelineAlpha(0.6).cgColor
    }
}

/// "Working for 12s" while a turn runs; the timeline ticks it every second.
final class WorkingRowView: TimelineRowView {
    private let label = NSTextField.timelineLabel("", size: Typography.bodySize)
    private let rule = NSView()
    private var startedAt: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.tabular(Typography.bodySize)
        addSubview(label)
        addSubview(rule)
        rule.wantsLayer = true
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .working(startedAt) = row.content else { return }
        self.startedAt = startedAt
        tick()
    }

    /// Re-reads the clock.
    func tick(now: Date = Date()) {
        guard let startedAt else { return }
        label.stringValue = "Working for \(Self.elapsed(since: startedAt, now: now))"
    }

    /// "12s" under a minute, else "1m 12s".
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : DurationText.turn(Double(seconds))
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        label.frame = NSRect(x: 4, y: 4 + (24 - label.lineHeight) / 2, width: width - 8, height: label.lineHeight)
        rule.frame = NSRect(x: 0, y: 4 + 24 + 8, width: width, height: 1)
        return 4 + 24 + 8 + 1
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
        rule.layer?.backgroundColor = palette.border.timelineAlpha(0.6).cgColor
    }
}

// MARK: - Work group / entry

/// A work group's summary row ("Read 2 files and ran 1 command") with its icon and chevron.
final class WorkGroupRowView: ClickableRowView {
    private let line = WorkLogLineView()
    private var model: WorkGroupRowModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(line)
        line.chevronAfterLabel = true
        onToggle = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineToggleGroup(model.groupID)
        }
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .workGroup(model) = row.content else { return }
        self.model = model
        line.icon.setSymbol(model.icon, size: 13)
        line.chevron.setSymbol(model.expanded ? Icon.chevronDown : Icon.chevronRight, size: 10, weight: .medium)
        line.time.stringValue = TimelineFormat.timestamp(model.date)
        line.failMark.isHidden = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(model.failed ? "\(model.summary), tool call failed" : model.summary)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        line.showsTime = isHovered
        line.frame = NSRect(x: 0, y: 2, width: width, height: WorkLogLineView.height)
        line.layoutLine(width: width)
        headerRect = NSRect(x: 0, y: 0, width: width, height: 28)
        window?.invalidateCursorRects(for: self)
        return 28
    }

    override func hoverChanged() {
        _ = layoutRow(width: bounds.width)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        guard let model else { return }
        let color = isHovered ? palette.foreground : palette.secondaryLabel
        line.label.set(model.summary, font: Typography.ui(Typography.bodySize), color: color, highlightColor: color)
        line.applyColors(palette: palette, labelColor: color, failed: model.failed)
    }
}

/// One work-log entry ("Ran command  swift build", "Changed App.swift", "Read …") that expands to
/// its output (SF Mono 13, at most 256 pt, scrolls).
final class WorkEntryRowView: ClickableRowView {
    static let bodyMaxHeight: CGFloat = 256

    private let line = WorkLogLineView()
    private let bodyScroll = PassThroughScrollView()
    private let bodyText = MarkdownTextView()
    private let bodyMarkdown = MarkdownView(frame: .zero)
    private let bodyPanel = FlippedView()
    private var model: WorkEntryRowModel?
    private var bodyString = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(line)
        addSubview(bodyPanel)
        bodyPanel.wantsLayer = true
        bodyPanel.layer?.cornerRadius = Radius.md
        bodyPanel.addSubview(bodyScroll)
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.documentView = bodyText
        addSubview(bodyMarkdown)
        onToggle = { [weak self] in
            guard let self, let model, model.entry.canExpand else { return }
            delegate?.timelineToggleEntry(model.entry.id)
        }
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .workEntry(model) = row.content else { return }
        self.model = model
        let entry = model.entry
        line.icon.setSymbol(entry.icon, size: 13)
        // An open thought shows its full text below; the line then just says "Thought".
        line.detail.stringValue = entry.kind == .reasoning && model.expanded ? "" : (entry.detail ?? "")
        line.detail.font = entry.detailIsCode ? Typography.mono(Typography.smallSize) : Typography.ui(Typography.bodySize)
        line.note.stringValue = entry.note ?? ""
        line.failMark.isHidden = true
        line.time.stringValue = TimelineFormat.timestamp(entry.startedAt)
        line.showsChevron = entry.canExpand
        line.chevron.setSymbol(model.expanded ? Icon.chevronDown : Icon.chevronRight, size: 10, weight: .medium)
        let expanded = model.expanded && entry.canExpand
        bodyPanel.isHidden = !expanded || entry.bodyIsMarkdown
        bodyMarkdown.isHidden = !expanded || !entry.bodyIsMarkdown
        if expanded {
            if entry.bodyIsMarkdown {
                bodyMarkdown.apply(MarkdownRenderer.render(entry.body ?? "", style: .thought))
            } else {
                bodyString = Self.bodyText(entry.body ?? "", palette: palette)
                bodyText.setText(bodyString)
            }
        }
        setAccessibilityRole(entry.canExpand ? .button : .row)
        setAccessibilityLabel(entry.isFailed ? "\(model.displayLabel ?? entry.label), tool call failed" : (model.displayLabel ?? entry.label))
        onToggle = entry.canExpand ? { [weak self] in
            guard let self, let model = self.model else { return }
            delegate?.timelineToggleEntry(model.entry.id)
        } : nil
        applyPalette(palette)
    }

    private static func bodyText(_ text: String, palette: Palette) -> NSAttributedString {
        let font = Typography.mono(Typography.codeSize)
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = (Typography.codeSize * 1.625).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: palette.secondaryLabel,
            .paragraphStyle: paragraph,
            .baselineOffset: (lineHeight - font.ascender + font.descender) / 4,
        ])
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        let pad: CGFloat = model.grouped ? 0 : 2
        line.showsTime = isHovered
        line.frame = NSRect(x: 0, y: pad, width: width, height: WorkLogLineView.height)
        line.layoutLine(width: width)
        var y = pad + WorkLogLineView.height
        headerRect = NSRect(x: 0, y: 0, width: width, height: y + pad)
        window?.invalidateCursorRects(for: self)
        if !bodyMarkdown.isHidden {
            y += 2
            bodyMarkdown.frame.origin = NSPoint(x: 30, y: y)
            y += bodyMarkdown.layoutMarkdown(width: width - 30 - 4) + 8
        } else if !bodyPanel.isHidden {
            y += 2
            let inner = width - 30 - 16
            let textHeight = TextMeasure.height(bodyString, width: inner)
            let shown = min(textHeight, Self.bodyMaxHeight)
            bodyPanel.frame = NSRect(x: 30, y: y, width: width - 30, height: shown + 16)
            bodyScroll.frame = NSRect(x: 8, y: 8, width: inner + 8, height: shown)
            bodyText.setWidth(inner, height: textHeight)
            y += shown + 16 + 8
        }
        return y + pad
    }

    override func hoverChanged() {
        line.showsTime = isHovered
        line.layoutLine(width: bounds.width)
    }

    override func applyPalette(_ palette: Palette) {
        guard let model else { return }
        let entry = model.entry
        let labelColor = entry.isToolLike ? palette.secondaryLabel : palette.foreground.timelineAlpha(0.8)
        line.label.set(model.displayLabel ?? entry.label, font: Typography.ui(Typography.bodySize), color: labelColor, highlightColor: labelColor)
        line.applyColors(palette: palette, labelColor: labelColor, failed: entry.isFailed)
        bodyPanel.layer?.backgroundColor = palette.foreground.timelineAlpha(palette.isDark ? 0.04 : 0.03).cgColor
        bodyText.applyColors(palette, quoteColor: .clear)
        bodyMarkdown.setQuoteColor(palette.foreground.timelineAlpha(0.3))
    }
}

/// The running turn's current tool, shimmering, with the latest thought above it (up to 4 lines);
/// clicking shows the group's entries. Also the "Thinking" row.
final class LiveWorkRowView: ClickableRowView {
    private let thoughtIcon = TimelineIconView(symbol: TimelineIcon.workReasoning, size: 13)
    private let thoughtLabel = NSTextField(wrappingLabelWithString: "")
    private let line = WorkLogLineView()
    private var model: LiveWorkRowModel?
    private var isThinking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(thoughtIcon)
        addSubview(thoughtLabel)
        addSubview(line)
        thoughtLabel.font = Typography.ui(Typography.bodySize)
        thoughtLabel.maximumNumberOfLines = 4
        thoughtLabel.lineBreakMode = .byTruncatingTail
        thoughtLabel.cell?.truncatesLastVisibleLine = true
        thoughtLabel.isSelectable = false
        line.chevronSlot = false
        onToggle = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineToggleGroup(model.groupID)
        }
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        switch row.content {
        case let .liveWork(model):
            self.model = model
            isThinking = false
            line.icon.setSymbol(model.entry.icon, size: 13)
            thoughtLabel.stringValue = model.thought ?? ""
            line.failMark.isHidden = true
            onToggle = { [weak self] in
                guard let self, let model = self.model else { return }
                delegate?.timelineToggleGroup(model.groupID)
            }
            setAccessibilityLabel(WorkLog.liveLabel(model.entry))
        case .thinking:
            model = nil
            isThinking = true
            line.icon.setSymbol(TimelineIcon.workReasoning, size: 13)
            thoughtLabel.stringValue = ""
            line.failMark.isHidden = true
            onToggle = nil
            setAccessibilityLabel("Thinking")
        default:
            return
        }
        line.detail.stringValue = ""
        line.note.stringValue = ""
        line.label.isShimmering = isThinking || (model?.active ?? false)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        var y: CGFloat = 2
        let showsThought = !thoughtLabel.stringValue.isEmpty && !(model?.expanded ?? false) && model?.entry.kind != .reasoning
        thoughtIcon.isHidden = !showsThought
        thoughtLabel.isHidden = !showsThought
        if showsThought {
            let textWidth = width - 32 - 4
            let height = min(ceil(thoughtLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 20), 4 * 20 + 4)
            thoughtIcon.frame = NSRect(x: 6, y: y + 4, width: 16, height: 16)
            thoughtLabel.frame = NSRect(x: 32, y: y + 2, width: textWidth, height: height)
            y += max(24, height + 4)
        }
        line.frame = NSRect(x: 0, y: y, width: width, height: WorkLogLineView.height)
        line.layoutLine(width: width)
        y += WorkLogLineView.height
        headerRect = NSRect(x: 0, y: 0, width: width, height: y + 2)
        window?.invalidateCursorRects(for: self)
        return y + 2
    }

    override func applyPalette(_ palette: Palette) {
        let text = isThinking ? "Thinking" : model.map { WorkLog.liveLabel($0.entry) } ?? ""
        line.label.set(text, font: Typography.ui(Typography.bodySize), color: palette.secondaryLabel, highlightColor: palette.foreground)
        line.applyColors(palette: palette, labelColor: palette.secondaryLabel, failed: false)
        line.icon.contentTintColor = palette.foreground
        thoughtIcon.contentTintColor = palette.mutedForeground
        thoughtLabel.textColor = palette.secondaryLabel
    }
}

/// A scroll view that hands scrolling to the timeline when it has nothing to scroll.
final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let document = documentView, document.frame.height > contentView.bounds.height + 1 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let atTop = contentView.bounds.minY <= 0
        let atBottom = contentView.bounds.maxY >= document.frame.height - 1
        if (event.scrollingDeltaY > 0 && atTop) || (event.scrollingDeltaY < 0 && atBottom) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}
