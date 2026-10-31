import AppKit
import SopranoAgentsCore

// MARK: - Approval

/// A pending approval row: kind icon and title, the command or path in mono,
/// the reason, then "Waiting for approval · Decline Approve More".
final class ApprovalRowView: TimelineRowView {
    private let line = WorkLogLineView()
    private let detailScroll = PassThroughScrollView()
    private let detailText = MarkdownTextView()
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let shieldIcon = TimelineIconView(symbol: TimelineIcon.shield, size: 10)
    private let waitingLabel = NSTextField.timelineLabel("Waiting for approval", size: Typography.smallSize)
    private let dotLabel = NSTextField.timelineLabel("·", size: Typography.smallSize)
    private let declineButton = TimelineButton("Decline", variant: .inline(muted: true), height: 20)
    private let approveButton = TimelineButton("Approve", variant: .inline(muted: false), height: 20)
    private let moreButton = TimelineButton("More", variant: .inline(muted: true), height: 20, toolTip: "More approval options")
    private var request: ApprovalRequest?
    private var detailString = NSAttributedString()

    static let detailMaxHeight: CGFloat = 160

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [line, detailScroll, reasonLabel, shieldIcon, waitingLabel, dotLabel, declineButton, approveButton, moreButton] as [NSView] {
            addSubview(view)
        }
        line.chevronSlot = false
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.scrollerStyle = .overlay
        detailScroll.documentView = detailText
        reasonLabel.font = Typography.ui(Typography.smallSize)
        reasonLabel.isSelectable = true
        declineButton.onClick = { [weak self] in self?.respond(.decline) }
        approveButton.onClick = { [weak self] in self?.respond(.accept) }
        moreButton.onClick = { [weak self] in self?.showMore() }
        applyPalette(palette)
    }

    private func respond(_ decision: ApprovalDecision) {
        guard let request else { return }
        delegate?.timelineRespond(approvalID: request.id, decision: decision)
    }

    private var moreOptions: [ApprovalDecision] {
        (request?.options ?? []).filter { $0 != .accept && $0 != .decline }
    }

    private func showMore() {
        let menu = NSMenu()
        for decision in moreOptions {
            let item = NSMenuItem(title: decision.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = decision.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: self)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let decision = ApprovalDecision(rawValue: raw) else { return }
        respond(decision)
    }

    static func icon(for kind: ApprovalKind) -> String {
        switch kind {
        case .command: TimelineIcon.workCommand
        case .fileChange: TimelineIcon.workEdit
        case .fileRead: TimelineIcon.workRead
        case .other: TimelineIcon.shield
        }
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .approval(model) = row.content else { return }
        request = model.request
        line.icon.setSymbol(Self.icon(for: model.request.kind), size: 13)
        line.failMark.isHidden = true
        line.detail.stringValue = ""
        line.note.stringValue = ""
        reasonLabel.stringValue = model.request.reason ?? ""
        reasonLabel.isHidden = (model.request.reason ?? "").isEmpty
        let options = model.request.options
        declineButton.isHidden = !options.contains(.decline)
        approveButton.isHidden = !options.contains(.accept)
        moreButton.isHidden = moreOptions.isEmpty
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.request.kind.title)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        line.frame = NSRect(x: 0, y: 2, width: width, height: WorkLogLineView.height)
        line.layoutLine(width: width)
        var y = 2 + WorkLogLineView.height
        let inset: CGFloat = 32
        let inner = width - inset - 4
        let detailHeight = TextMeasure.height(detailString, width: inner)
        if detailHeight > 0 {
            let shown = min(detailHeight, Self.detailMaxHeight)
            detailScroll.isHidden = false
            detailScroll.frame = NSRect(x: inset, y: y, width: inner + 4, height: shown)
            detailText.setWidth(inner, height: detailHeight)
            y += shown + 4
        } else {
            detailScroll.isHidden = true
        }
        if !reasonLabel.isHidden {
            let height = ceil(reasonLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 16)
            reasonLabel.frame = NSRect(x: inset - 2, y: y, width: inner, height: height)
            y += height + 4
        }
        // "Waiting for approval · Decline Approve More"
        var x = inset + 2
        shieldIcon.frame = NSRect(x: x, y: y + 4, width: 12, height: 12)
        x += 12 + 4
        let waitingWidth = waitingLabel.textFitWidth
        waitingLabel.frame = NSRect(x: x, y: y + 2, width: waitingWidth, height: 16)
        x += waitingWidth + 8
        let dotWidth = dotLabel.textFitWidth
        dotLabel.frame = NSRect(x: x, y: y + 2, width: dotWidth, height: 16)
        x += dotWidth + 8
        for button in [declineButton, approveButton, moreButton] where !button.isHidden {
            let buttonWidth = button.fittingWidth
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: 20)
            x += buttonWidth + 8
        }
        y += 20 + 4
        return y
    }

    override func applyPalette(_ palette: Palette) {
        guard let request else { return }
        line.label.set(request.kind.title, font: Typography.ui(Typography.bodySize), color: palette.secondaryLabel, highlightColor: palette.secondaryLabel)
        line.applyColors(palette: palette, labelColor: palette.secondaryLabel, failed: false)
        let font = Typography.mono(Typography.smallSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        paragraph.lineBreakMode = .byCharWrapping
        detailString = NSAttributedString(string: request.detail.isEmpty ? request.kind.title : request.detail, attributes: [
            .font: font, .foregroundColor: palette.foreground, .paragraphStyle: paragraph,
            .baselineOffset: (20 - font.ascender + font.descender) / 4,
        ])
        detailText.setText(detailString)
        detailText.applyColors(palette, quoteColor: .clear)
        reasonLabel.textColor = palette.mutedForeground
        shieldIcon.contentTintColor = palette.warningForeground
        waitingLabel.textColor = palette.warningForeground
        dotLabel.textColor = palette.mutedForeground
    }
}

// MARK: - Error / notice

/// A failure in the error color with its time.
final class ErrorRowView: TimelineRowView {
    private let icon = TimelineIconView(symbol: Icon.circleAlert, size: 13)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let time = NSTextField.timelineLabel("", size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, messageLabel, time] as [NSView] { addSubview(view) }
        messageLabel.font = Typography.ui(Typography.bodySize, weight: .medium)
        messageLabel.isSelectable = true
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .error(message, date) = row.content else { return }
        messageLabel.stringValue = message
        time.stringValue = TimelineFormat.timestamp(date)
        time.toolTip = TimelineFormat.tooltip(date)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        let timeWidth = time.textFitWidth
        time.frame = NSRect(x: width - 2 - timeWidth, y: 2 + 4, width: timeWidth, height: 16)
        let textWidth = max(0, time.frame.minX - 8 - 32)
        let height = max(20, ceil(messageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 20))
        icon.frame = NSRect(x: 6, y: 2 + 4, width: 16, height: 16)
        messageLabel.frame = NSRect(x: 32, y: 2 + 2, width: textWidth, height: height)
        return max(28, height + 8)
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.error
        messageLabel.textColor = palette.errorForeground
        time.textColor = palette.mutedForeground
    }
}

/// "Context compacted" divider: hairlines on both sides of a muted label.
final class NoticeRowView: TimelineRowView {
    private let leftRule = NSView()
    private let rightRule = NSView()
    private let icon = TimelineIconView(symbol: TimelineIcon.minimize, size: 10)
    private let label = NSTextField.timelineLabel("", size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [leftRule, rightRule, icon, label] as [NSView] { addSubview(view) }
        leftRule.wantsLayer = true
        rightRule.wantsLayer = true
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .notice(text) = row.content else { return }
        label.stringValue = text
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        let labelWidth = min(label.textFitWidth, width - 80)
        let contentWidth = 12 + 6 + labelWidth
        let x = (width - contentWidth) / 2
        icon.frame = NSRect(x: x, y: 6, width: 12, height: 12)
        label.frame = NSRect(x: x + 18, y: 4, width: labelWidth, height: 16)
        leftRule.frame = NSRect(x: 0, y: 12, width: max(0, x - 12), height: 1)
        rightRule.frame = NSRect(x: label.frame.maxX + 12, y: 12, width: max(0, width - label.frame.maxX - 12), height: 1)
        return 24
    }

    override func applyPalette(_ palette: Palette) {
        for rule in [leftRule, rightRule] { rule.layer?.backgroundColor = palette.border.timelineAlpha(0.7).cgColor }
        icon.contentTintColor = palette.mutedForeground
        label.textColor = palette.mutedForeground
    }
}

/// An advisor note: "Final reviewer · Concern" (severity colored) with its time, the note as
/// Markdown under it.
final class AdvisoryRowView: TimelineRowView {
    private let icon = TimelineIconView(symbol: TimelineIcon.advisor, size: 13)
    private let header = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let time = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let markdown = MarkdownView(frame: .zero)
    private var model: AdvisoryRowModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, header, time, markdown] as [NSView] { addSubview(view) }
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .advisory(model) = row.content else { return }
        self.model = model
        markdown.apply(MarkdownRenderer.render(model.note.text, style: .thought))
        time.stringValue = TimelineFormat.timestamp(model.date)
        time.toolTip = TimelineFormat.tooltip(model.date)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(model.note.advisor ?? "Advisor") \(model.note.severity.title)")
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        let timeWidth = time.textFitWidth
        time.frame = NSRect(x: width - 2 - timeWidth, y: 2 + 2, width: timeWidth, height: 16)
        icon.frame = NSRect(x: 6, y: 2 + 2, width: 16, height: 16)
        header.frame = NSRect(x: 32, y: 2 + 2, width: max(0, min(header.textFitWidth, time.frame.minX - 8 - 32)), height: 16)
        markdown.frame.origin = NSPoint(x: 32, y: 2 + 22)
        let height = markdown.layoutMarkdown(width: max(0, width - 32 - 4))
        return 2 + 22 + height + 2
    }

    override func applyFind(_ highlights: [FindHighlight]) {
        markdown.applyFind(highlights)
    }

    override func findRect(unit: Int, range: NSRange) -> NSRect? {
        markdown.findRect(unit: unit, range: range).map { $0.offsetBy(dx: markdown.frame.minX, dy: markdown.frame.minY) }
    }

    override func applyPalette(_ palette: Palette) {
        let severity = model?.note.severity ?? .nit
        let tint: NSColor = switch severity {
        case .blocker: palette.errorForeground
        case .concern: palette.warningForeground
        case .nit: palette.mutedForeground
        }
        icon.contentTintColor = tint
        let text = NSMutableAttributedString(string: model?.note.advisor ?? "Advisor", attributes: [
            .font: Typography.ui(Typography.smallSize, weight: .medium), .foregroundColor: palette.secondaryLabel,
        ])
        text.append(NSAttributedString(string: " · \(severity.title)", attributes: [
            .font: Typography.ui(Typography.smallSize), .foregroundColor: tint,
        ]))
        header.attributedStringValue = text
        time.textColor = palette.mutedForeground
        markdown.setQuoteColor(palette.foreground.timelineAlpha(0.8 * 0.35))
    }
}

/// "Background work still running…" under a yielded turn: its answer is final while jobs the
/// agent started still run (and may wake it). One muted line.
final class BackgroundWorkRowView: TimelineRowView {
    private let icon = TimelineIconView(symbol: Icon.circleDashed, size: 11)
    private let label = NSTextField.timelineLabel("Background work still running…", size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(icon)
        addSubview(label)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        icon.frame = NSRect(x: 4, y: 6, width: 12, height: 12)
        label.frame = NSRect(x: 22, y: 4, width: max(0, min(label.textFitWidth, width - 26)), height: 16)
        return 24
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.mutedForeground
        label.textColor = palette.mutedForeground
    }
}
