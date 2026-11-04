import AppKit
import SopranoAgentsCore

/// Width of the widest line of `rendering` when it is only prose (bubbles shrink to their text).
@MainActor
private func naturalWidth(of rendering: MarkdownRendering, limit: CGFloat) -> CGFloat {
    var widest: CGFloat = 0
    for piece in rendering.pieces {
        guard case let .text(text) = piece.segment else { return limit }
        let bounds = text.boundingRect(with: NSSize(width: limit, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        widest = max(widest, ceil(bounds.width) + 1)
    }
    return min(limit, max(widest, 8))
}

// MARK: - User message

/// A user message row: right-aligned bubble (`max-w-[80%] rounded-2xl p-3
/// bg-message`), attachments above the text, long text folded at 176 pt with "Show full message",
/// "↪ Steer" marker, hover footer with timestamp, "Edit from here" and "Copy message".
final class UserMessageRowView: TimelineRowView {
    static let collapsedHeight: CGFloat = 176
    static let footerHeight: CGFloat = 24

    private let steerIcon = TimelineIconView(symbol: TimelineIcon.redo, size: 11)
    private let steerLabel = NSTextField.timelineLabel("Steer", size: Typography.smallSize)
    private let bubble = PaletteFill(role: .messageSurface, radius: Radius.xxl)
    private let textClip = FlippedView()
    private let markdown = MarkdownView(frame: .zero)
    private let fade = GradientFill()
    private let toggleButton = TimelineButton("Show full message", variant: .ghostMuted)
    private let footer = FlippedView()
    private let timeLabel = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let editButton = TimelineButton(symbol: TimelineIcon.pencil, variant: .ghostMuted, toolTip: "Edit from here")
    private lazy var copyButton = CopyButton.make(text: { [weak self] in self?.model?.message.text ?? "" }, delegate: { [weak self] in self?.delegate })
    private var attachmentViews: [NSView] = []
    private var model: UserRowModel?

    override var tracksHover: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [steerIcon, steerLabel, bubble, footer] as [NSView] { addSubview(view) }
        bubble.addSubview(textClip)
        textClip.wantsLayer = true
        textClip.layer?.masksToBounds = true
        textClip.addSubview(markdown)
        bubble.addSubview(fade)
        bubble.addSubview(toggleButton)
        for view in [timeLabel, editButton, copyButton] as [NSView] { footer.addSubview(view) }
        steerLabel.toolTip = "Steered the active turn"
        footer.wantsLayer = true
        footer.alphaValue = 0
        toggleButton.onClick = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineToggleMessage(model.message.id)
        }
        editButton.onClick = { [weak self] in
            guard let self, let turnID = model?.turnID else { return }
            delegate?.timelineEditFromHere(turnID: turnID)
        }
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .user(model) = row.content else { return }
        let changedAttachments = model.message.attachments != self.model?.message.attachments
        self.model = model
        markdown.apply(MarkdownRenderer.render(model.message.text, style: .user))
        let isSteer = model.turnID == nil
        steerIcon.isHidden = !isSteer
        steerLabel.isHidden = !isSteer
        timeLabel.stringValue = TimelineFormat.timestamp(model.message.createdAt)
        timeLabel.toolTip = TimelineFormat.tooltip(model.message.createdAt)
        editButton.isHidden = model.turnID == nil || !model.editable
        editButton.isEnabled = model.canEdit
        toggleButton.title = model.expanded ? "Show less" : "Show full message"
        if changedAttachments { rebuildAttachments(model.message.attachments) }
    }

    private func rebuildAttachments(_ attachments: [Attachment]) {
        attachmentViews.forEach { $0.removeFromSuperview() }
        attachmentViews = attachments.map { attachment in
            let view = AttachmentChipView(attachment: attachment)
            bubble.addSubview(view)
            return view
        }
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        var y: CGFloat = 0
        let isSteer = model.turnID == nil
        if isSteer {
            let labelWidth = steerLabel.textFitWidth
            steerLabel.frame = NSRect(x: width - 4 - labelWidth, y: 0, width: labelWidth, height: 16)
            steerIcon.frame = NSRect(x: steerLabel.frame.minX - 4 - 12, y: 2, width: 12, height: 12)
            y = 16 + 4
        }
        let maxBubble = floor(width * 0.8)
        let padding: CGFloat = 12
        let maxContent = maxBubble - padding * 2
        let rendering = markdown.rendering
        let hasText = !model.message.text.isEmpty
        var contentWidth = rendering.map { naturalWidth(of: $0, limit: maxContent) } ?? 0
        let images = model.message.attachments.filter { $0.kind == .image }
        let files = model.message.attachments.filter { $0.kind == .file }
        let gridWidth: CGFloat = images.isEmpty ? 0 : min(210, maxContent)
        if !images.isEmpty { contentWidth = max(contentWidth, gridWidth) }
        if !files.isEmpty { contentWidth = maxContent }
        if !hasText, attachmentViews.isEmpty { contentWidth = 0 }

        // Attachments: images in a 2-column grid (4:3 tiles), files as rows.
        var inner: CGFloat = padding
        var imageIndex = 0
        let tileWidth = floor((gridWidth - 8) / 2)
        let tileHeight = floor(tileWidth * 3 / 4)
        var fileY: CGFloat = 0
        let imageRows = (images.count + 1) / 2
        let gridHeight = imageRows == 0 ? 0 : CGFloat(imageRows) * tileHeight + CGFloat(imageRows - 1) * 8
        for (index, attachment) in model.message.attachments.enumerated() where index < attachmentViews.count {
            let view = attachmentViews[index]
            if attachment.kind == .image {
                let column = CGFloat(imageIndex % 2)
                let row = CGFloat(imageIndex / 2)
                view.frame = NSRect(x: padding + column * (tileWidth + 8), y: inner + row * (tileHeight + 8), width: tileWidth, height: tileHeight)
                imageIndex += 1
            } else {
                view.frame = NSRect(x: padding, y: inner + gridHeight + (gridHeight > 0 ? 8 : 0) + fileY, width: contentWidth, height: 28)
                fileY += 28 + 4
            }
        }
        if !model.message.attachments.isEmpty {
            inner += gridHeight + (gridHeight > 0 && fileY > 0 ? 8 : 0) + fileY + (hasText ? 8 : 0)
        }

        // Text, folded at 176 pt; "Show full message" sits under it inside the bubble.
        let fullHeight = hasText ? markdown.layoutMarkdown(width: contentWidth) : 0
        let collapsible = fullHeight > Self.collapsedHeight + 24
        let shownHeight = collapsible && !model.expanded ? Self.collapsedHeight : fullHeight
        markdown.frame.origin = .zero
        textClip.frame = NSRect(x: padding, y: inner, width: contentWidth, height: shownHeight)
        textClip.isHidden = !hasText
        fade.isHidden = !(collapsible && !model.expanded)
        fade.frame = NSRect(x: padding, y: inner + shownHeight - 28, width: contentWidth, height: 28)
        inner += shownHeight
        toggleButton.isHidden = !collapsible
        if collapsible {
            let buttonWidth = toggleButton.fittingWidth
            contentWidth = max(contentWidth, buttonWidth)
            toggleButton.frame = NSRect(x: padding + contentWidth - buttonWidth + 4, y: inner + 6, width: buttonWidth, height: 24)
            inner += 6 + 24
        }
        inner += padding
        bubble.frame = NSRect(x: width - contentWidth - padding * 2, y: y, width: contentWidth + padding * 2, height: inner)
        bubble.layer?.masksToBounds = true
        y += inner

        // Hover footer: timestamp, Edit from here, Copy message.
        y += 4
        let footerWidth = maxBubble
        footer.frame = NSRect(x: width - footerWidth, y: y, width: footerWidth, height: Self.footerHeight)
        var x = footerWidth - 4
        copyButton.frame = NSRect(x: x - 24, y: 0, width: 24, height: 24)
        x -= 24 + 2
        if !editButton.isHidden {
            editButton.frame = NSRect(x: x - 24, y: 0, width: 24, height: 24)
            x -= 24
        }
        let timeWidth = timeLabel.textFitWidth
        timeLabel.frame = NSRect(x: x - 8 - timeWidth, y: 4, width: timeWidth, height: 16)
        y += Self.footerHeight
        return y
    }

    override func hoverChanged() {
        footer.alphaValue = isHovered ? 1 : 0
    }

    override func applyFind(_ highlights: [FindHighlight]) {
        markdown.applyFind(highlights)
    }

    override func findRect(unit: Int, range: NSRange) -> NSRect? {
        markdown.findRect(unit: unit, range: range).map { $0.offsetBy(dx: bubble.frame.minX + textClip.frame.minX, dy: bubble.frame.minY + textClip.frame.minY) }
    }

    override func applyPalette(_ palette: Palette) {
        steerIcon.contentTintColor = palette.mutedForeground
        steerLabel.textColor = palette.mutedForeground
        timeLabel.textColor = palette.mutedForeground
        fade.colors = (palette.messageSurface.timelineAlpha(0), palette.messageSurface)
        markdown.setQuoteColor(palette.messageForeground.timelineAlpha(0.35))
    }
}

/// An attachment inside a user bubble: image tile (rounded 8, border) or file row.
final class AttachmentChipView: PaletteView {
    private let attachment: Attachment
    private let imageView = NSImageView()
    private let icon = TimelineIconView(symbol: TimelineIcon.file, size: 13)
    private let nameLabel = NSTextField.timelineLabel("", size: Typography.bodySize)

    init(attachment: Attachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        if attachment.kind == .image {
            layer?.cornerRadius = Radius.lg
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(contentsOfFile: attachment.path)
            imageView.toolTip = attachment.name
            addSubview(imageView)
            if imageView.image == nil {
                nameLabel.stringValue = attachment.name
                nameLabel.font = Typography.ui(Typography.tinySize)
                nameLabel.alignment = .center
                addSubview(nameLabel)
            }
        } else {
            nameLabel.stringValue = attachment.name
            addSubview(icon)
            addSubview(nameLabel)
        }
        toolTip = attachment.name
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        if attachment.kind == .image {
            imageView.frame = bounds
            nameLabel.frame = NSRect(x: 4, y: bounds.midY - 8, width: bounds.width - 8, height: 16)
        } else {
            icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
            nameLabel.frame = NSRect(x: 24, y: (bounds.height - 18) / 2, width: bounds.width - 24, height: 18)
        }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.borderColor = palette.border.timelineAlpha(0.8).cgColor
        layer?.backgroundColor = attachment.kind == .image ? palette.background.timelineAlpha(0.7).cgColor : NSColor.clear.cgColor
        icon.contentTintColor = palette.mutedForeground
        nameLabel.textColor = attachment.kind == .image ? palette.mutedForeground.timelineAlpha(0.7) : palette.messageForeground
    }
}

// MARK: - Assistant message

/// An assistant row: no bubble, Markdown at 14/1.625 `foreground/90`, the
/// changed-files card under the turn's answer, and a hover meta row (Copy message, timestamp).
final class AssistantRowView: TimelineRowView {
    private let markdown = MarkdownView(frame: .zero)
    private let emptyLabel = NSTextField.timelineLabel("(empty response)", size: Typography.bodySize)
    private let card = ChangedFilesCardView(frame: .zero)
    private let meta = FlippedView()
    private lazy var copyButton = CopyButton.make(text: { [weak self] in self?.model?.text ?? "" }, delegate: { [weak self] in self?.delegate })
    private let timeLabel = NSTextField.timelineLabel("", size: Typography.smallSize)
    private var model: AssistantRowModel?

    override var tracksHover: Bool { true }

    override weak var delegate: TimelineRowDelegate? {
        didSet { card.delegate = delegate }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [markdown, emptyLabel, card, meta] as [NSView] { addSubview(view) }
        meta.addSubview(copyButton)
        meta.addSubview(timeLabel)
        meta.wantsLayer = true
        meta.alphaValue = 0
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .assistant(model) = row.content else { return }
        self.model = model
        markdown.apply(MarkdownRenderer.render(model.text, style: .assistant))
        emptyLabel.isHidden = !(model.text.isEmpty && !model.isStreaming)
        card.isHidden = model.changedFiles == nil
        if let files = model.changedFiles { card.configure(files) }
        meta.isHidden = !model.showMeta
        timeLabel.stringValue = TimelineFormat.timestamp(model.date)
        timeLabel.toolTip = TimelineFormat.tooltip(model.date)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        let inner = width - 8
        var y: CGFloat = 2
        markdown.frame.origin = NSPoint(x: 4, y: y)
        if emptyLabel.isHidden {
            y += markdown.layoutMarkdown(width: inner)
        } else {
            emptyLabel.frame = NSRect(x: 4, y: y + 2, width: inner, height: 19)
            y += 23
        }
        if model.changedFiles != nil {
            y += 16
            card.frame.origin = NSPoint(x: 4, y: y)
            y += card.layoutCard(width: inner)
        }
        if model.showMeta {
            y += 6
            meta.frame = NSRect(x: 4, y: y, width: inner, height: 24)
            copyButton.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            let timeWidth = timeLabel.textFitWidth
            timeLabel.frame = NSRect(x: 24 + 8, y: 4, width: timeWidth, height: 16)
            y += 24
        }
        return y + 2
    }

    override func hoverChanged() {
        meta.alphaValue = isHovered ? 1 : 0
    }

    override func applyFind(_ highlights: [FindHighlight]) {
        markdown.applyFind(highlights)
    }

    override func findRect(unit: Int, range: NSRange) -> NSRect? {
        markdown.findRect(unit: unit, range: range).map { $0.offsetBy(dx: markdown.frame.minX, dy: markdown.frame.minY) }
    }

    override func applyPalette(_ palette: Palette) {
        emptyLabel.textColor = palette.mutedForeground
        timeLabel.textColor = palette.mutedForeground
        markdown.setQuoteColor(palette.foreground.timelineAlpha(0.9 * 0.35))
    }
}

/// Changed-files card of a turn without a closing answer.
final class ChangedFilesRowView: TimelineRowView {
    private let card = ChangedFilesCardView(frame: .zero)

    override weak var delegate: TimelineRowDelegate? {
        didSet { card.delegate = delegate }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        if case let .changedFiles(model) = row.content { card.configure(model) }
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        card.frame.origin = NSPoint(x: 4, y: 0)
        return card.layoutCard(width: width - 8)
    }
}

// MARK: - Queued message

/// A message waiting for the running turn: dashed bubble at the end with "Send now" / "Remove".
final class QueuedMessageRowView: TimelineRowView {
    private let bubble = DashedFill()
    private let markdown = MarkdownView(frame: .zero)
    private let queuedLabel = NSTextField.timelineLabel("Queued", size: Typography.smallSize)
    private let sendButton = TimelineButton("Send now", symbol: Icon.arrowUp, variant: .ghostMuted)
    private let removeButton = TimelineButton("Remove", symbol: TimelineIcon.close, variant: .ghostMuted)
    private var message: UserMessage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [bubble, queuedLabel, sendButton, removeButton] as [NSView] { addSubview(view) }
        bubble.addSubview(markdown)
        sendButton.onClick = { [weak self] in
            guard let self, let message else { return }
            delegate?.timelineSendQueuedNow(messageID: message.id)
        }
        removeButton.onClick = { [weak self] in
            guard let self, let message else { return }
            delegate?.timelineRemoveQueued(messageID: message.id)
        }
        applyPalette(palette)
    }

    override func configure(_ row: TimelineRow) {
        super.configure(row)
        guard case let .queued(message) = row.content else { return }
        self.message = message
        markdown.apply(MarkdownRenderer.render(message.text.isEmpty ? "(attachments)" : message.text, style: .user))
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        guard let rendering = markdown.rendering else { return 0 }
        let maxContent = floor(width * 0.8) - 24
        let contentWidth = naturalWidth(of: rendering, limit: maxContent)
        let textHeight = markdown.layoutMarkdown(width: contentWidth)
        markdown.frame.origin = NSPoint(x: 12, y: 12)
        bubble.frame = NSRect(x: width - contentWidth - 24, y: 0, width: contentWidth + 24, height: textHeight + 24)
        var y = bubble.frame.maxY + 4
        let removeWidth = removeButton.fittingWidth
        let sendWidth = sendButton.fittingWidth
        removeButton.frame = NSRect(x: width - removeWidth, y: y, width: removeWidth, height: 24)
        sendButton.frame = NSRect(x: removeButton.frame.minX - 4 - sendWidth, y: y, width: sendWidth, height: 24)
        let labelWidth = queuedLabel.textFitWidth
        queuedLabel.frame = NSRect(x: sendButton.frame.minX - 8 - labelWidth, y: y + 4, width: labelWidth, height: 16)
        y += 24
        return y
    }

    override func applyPalette(_ palette: Palette) {
        queuedLabel.textColor = palette.mutedForeground
        bubble.strokeColor = palette.input
        markdown.setQuoteColor(palette.messageForeground.timelineAlpha(0.35))
    }
}

// MARK: - Empty

/// "Send a message to start the conversation." centered in the timeline.
final class EmptyRowView: TimelineRowView {
    private let label = NSTextField.timelineLabel("Send a message to start the conversation.", size: Typography.bodySize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        addSubview(label)
        applyPalette(palette)
    }

    override func layoutRow(width: CGFloat) -> CGFloat {
        label.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: width, height: 20)
        return 20
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
    }
}

// MARK: - Fills

/// A rounded fill in one palette role.
final class PaletteFill: PaletteView {
    enum Role {
        case messageSurface
        case card
        case secondary
    }

    private let role: Role

    init(role: Role, radius: CGFloat) {
        self.role = role
        super.init(frame: .zero)
        layer?.cornerRadius = radius
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let color: NSColor = switch role {
        case .messageSurface: palette.messageSurface
        case .card: palette.card
        case .secondary: palette.isDark ? palette.input.timelineAlpha(0.2) : palette.secondary
        }
        layer?.backgroundColor = color.cgColor
    }
}

/// A vertical gradient (fade-out over clipped content).
final class GradientFill: NSView {
    private let gradient = CAGradientLayer()

    var colors: (NSColor, NSColor) = (.clear, .clear) {
        didSet { gradient.colors = [colors.0.cgColor, colors.1.cgColor] }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Unflipped so the gradient's unit space reads bottom-up: start (top) clear, end (bottom) opaque.
    override var isFlipped: Bool { false }

    override func makeBackingLayer() -> CALayer { gradient }
}

/// A rounded rectangle with a dashed 1 pt outline (queued messages).
final class DashedFill: NSView {
    private let shape = CAShapeLayer()

    var strokeColor: NSColor = .clear {
        didSet { shape.strokeColor = strokeColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineWidth = 1
        shape.lineDashPattern = [4, 3]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        shape.frame = bounds
        shape.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Radius.xxl, cornerHeight: Radius.xxl, transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        shape.frame = bounds
        shape.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Radius.xxl, cornerHeight: Radius.xxl, transform: nil)
    }
}
