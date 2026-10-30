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
        case .permission: TimelineIcon.workTool
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

// MARK: - Plan

/// The proposed plan card: rounded 16 card, "Plan" badge, title from the first heading,
/// "Plan actions" menu (Copy to clipboard), Markdown body folded at 416 pt with a fade and
/// "Expand plan" / "Collapse plan".
final class PlanRowView: TimelineRowView {
    static let collapsedHeight: CGFloat = 416

    private let card = FlippedView()
    private let badge = BadgeView(text: "Plan")
    private let titleLabel = NSTextField.timelineLabel("", size: Typography.bodySize, weight: .medium)
    private let menuButton = TimelineButton(symbol: TimelineIcon.ellipsis, variant: .outline, toolTip: "Plan actions")
    private let clip = FlippedView()
    private let markdown = MarkdownView(frame: .zero)
    private let fade = GradientFill()
    private let toggleButton = TimelineButton("Expand plan", variant: .outline, fontSize: Typography.rowSize, height: 28)
    private var model: PlanRowModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        card.wantsLayer = true
        card.layer?.cornerRadius = Radius.xxl
        card.layer?.borderWidth = 1
        for view in [badge, titleLabel, menuButton, clip, fade, toggleButton] as [NSView] { card.addSubview(view) }
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(markdown)
        menuButton.onClick = { [weak self] in self?.showMenu() }
        toggleButton.onClick = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineTogglePlan(model.itemID)
        }
        applyPalette(palette)
    }

    private func showMenu() {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy to clipboard", action: #selector(copyPlan), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.maxX - 160, y: menuButton.frame.maxY + 4), in: card)
    }

    @objc private func copyPlan() {
        guard let model else { return }
        delegate?.timelineCopy(model.markdown)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .plan(model) = row.content else { return }
        self.model = model
        titleLabel.stringValue = model.title
        markdown.apply(MarkdownRenderer.render(MarkdownDocument.strippingTitle(model.markdown), style: .plan))
        toggleButton.title = model.expanded ? "Collapse plan" : "Expand plan"
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        let padding: CGFloat = 20
        let inner = width - padding * 2
        let badgeWidth = badge.fittingWidth
        badge.frame = NSRect(x: padding, y: padding + 2, width: badgeWidth, height: 20)
        menuButton.frame = NSRect(x: width - padding - 24, y: padding, width: 24, height: 24)
        titleLabel.frame = NSRect(x: badge.frame.maxX + 8, y: padding + (24 - titleLabel.lineHeight) / 2, width: max(0, menuButton.frame.minX - 12 - badge.frame.maxX - 8), height: titleLabel.lineHeight)
        var y = padding + 24 + 16
        let fullHeight = markdown.layoutMarkdown(width: inner)
        markdown.frame.origin = .zero
        let collapsed = model.canCollapse && !model.expanded
        let shown = collapsed ? min(fullHeight, Self.collapsedHeight) : fullHeight
        clip.frame = NSRect(x: padding, y: y, width: inner, height: shown)
        fade.isHidden = !collapsed
        fade.frame = NSRect(x: padding, y: y + shown - 96, width: inner, height: 96)
        y += shown
        toggleButton.isHidden = !model.canCollapse
        if model.canCollapse {
            y += 16
            let buttonWidth = toggleButton.fittingWidth
            toggleButton.frame = NSRect(x: (width - buttonWidth) / 2, y: y, width: buttonWidth, height: 28)
            y += 28
        }
        y += padding
        card.frame = NSRect(x: 0, y: 0, width: width, height: y)
        return y
    }

    override func applyFind(_ highlights: [FindHighlight]) {
        markdown.applyFind(highlights)
    }

    override func findRect(unit: Int, range: NSRange) -> NSRect? {
        markdown.findRect(unit: unit, range: range).map { $0.offsetBy(dx: clip.frame.minX, dy: clip.frame.minY) }
    }

    override func applyPalette(_ palette: Palette) {
        card.layer?.backgroundColor = palette.card.timelineAlpha(0.7).cgColor
        card.layer?.borderColor = palette.border.timelineAlpha(0.8).cgColor
        titleLabel.textColor = palette.foreground
        let cardColor = palette.card
        fade.colors = (cardColor.timelineAlpha(0), cardColor.timelineAlpha(0.95))
        markdown.setQuoteColor(palette.foreground.timelineAlpha(0.35))
    }
}

/// A secondary badge: small rounded label.
final class BadgeView: PaletteView {
    private let label = NSTextField.timelineLabel("", size: Typography.smallSize, weight: .medium)

    init(text: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        label.stringValue = text
        addSubview(label)
        applyPalette(palette)
    }

    var fittingWidth: CGFloat { label.textFitWidth + 12 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: bounds.width - 12, height: 16)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.foreground.timelineAlpha(0.08) : palette.accent).cgColor
        label.textColor = palette.foreground
    }
}

// MARK: - Task list

/// The agent's task list: "Tasks 2/4 · Draft the new sidebar" with each step's status.
final class TodoRowView: TimelineRowView {
    private let card = PaletteFill(role: .secondary, radius: Radius.lg)
    private let icon = TimelineIconView(symbol: Icon.listTodo, size: 12)
    private let titleLabel = NSTextField.timelineLabel("", size: Typography.smallSize, weight: .medium)
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private var stepViews: [(icon: TimelineIconView, label: NSTextField)] = []
    private var model: TodoRowModel?

    static let stepHeight: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        for view in [icon, titleLabel, explanationLabel] as [NSView] { card.addSubview(view) }
        explanationLabel.font = Typography.ui(Typography.smallSize)
        explanationLabel.isSelectable = false
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .todo(model) = row.content else { return }
        self.model = model
        titleLabel.stringValue = WorkLog.todoTitle(model.steps)
        explanationLabel.stringValue = model.explanation ?? ""
        explanationLabel.isHidden = (model.explanation ?? "").isEmpty
        while stepViews.count < model.steps.count {
            let pair = (icon: TimelineIconView(), label: NSTextField.timelineLabel("", size: Typography.rowSize))
            card.addSubview(pair.icon)
            card.addSubview(pair.label)
            stepViews.append(pair)
        }
        for (index, pair) in stepViews.enumerated() {
            pair.icon.isHidden = index >= model.steps.count
            pair.label.isHidden = index >= model.steps.count
            guard index < model.steps.count else { continue }
            let step = model.steps[index]
            let symbol = switch step.status {
            case .completed: TimelineIcon.checkCircleFill
            case .inProgress: TimelineIcon.circleHalf
            case .pending: TimelineIcon.circle
            }
            pair.icon.setSymbol(symbol, size: 12)
            pair.label.stringValue = step.text
            pair.label.toolTip = step.text
        }
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        icon.frame = NSRect(x: 12, y: 12, width: 14, height: 14)
        titleLabel.frame = NSRect(x: 32, y: 11, width: width - 44, height: 16)
        var y: CGFloat = 36
        if !explanationLabel.isHidden {
            let height = ceil(explanationLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 24, height: 10_000)).height ?? 16)
            explanationLabel.frame = NSRect(x: 12, y: y, width: width - 24, height: height)
            y += height + 6
        }
        for (index, pair) in stepViews.enumerated() where index < model.steps.count {
            pair.icon.frame = NSRect(x: 12, y: y + (Self.stepHeight - 14) / 2, width: 14, height: 14)
            pair.label.frame = NSRect(x: 32, y: y + (Self.stepHeight - pair.label.lineHeight) / 2, width: width - 44, height: pair.label.lineHeight)
            y += Self.stepHeight
        }
        y += 8
        card.frame = NSRect(x: 4, y: 0, width: width - 8, height: y)
        return y
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.mutedForeground
        titleLabel.textColor = palette.foreground
        explanationLabel.textColor = palette.mutedForeground
        guard let model else { return }
        for (index, pair) in stepViews.enumerated() where index < model.steps.count {
            let status = model.steps[index].status
            pair.icon.contentTintColor = switch status {
            case .completed: palette.successForeground
            case .inProgress: palette.infoForeground
            case .pending: palette.mutedForeground.timelineAlpha(0.7)
            }
            pair.label.textColor = status == .completed ? palette.mutedForeground : palette.foreground.timelineAlpha(0.9)
        }
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
