import AppKit
import SopranoAgentsCore

// MARK: - Surface

/// The composer surface: r16 glass card (card / raised surface at 80% over a blur), a 1 pt
/// outline (black 8% light, white 5% dark), the composer shadow in light mode. Dragging files
/// over it fills it with `accent/45` and rings it with `primary/70`.
final class ComposerSurfaceView: PaletteView {
    private let blur = NSVisualEffectView()
    private let tint = PaletteView()
    private let ring = PaletteView()
    let content = ComposerColumn()

    var onFiles: (([URL]) -> Void)?
    var onImageData: ((Data) -> Void)?

    var isDragHighlighted = false {
        didSet { applyPalette(palette) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.xxl
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Radius.xxl
        blur.layer?.masksToBounds = true
        tint.layer?.cornerRadius = Radius.xxl
        ring.layer?.cornerRadius = Radius.xxl
        ring.layer?.borderWidth = 1
        for view in [blur, tint, content, ring] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        registerForDraggedTypes([.fileURL, .png, .tiff])
        applyPalette(palette)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === ring ? self : hit
    }

    override func applyPalette(_ palette: Palette) {
        blur.appearance = palette.appearance
        let accent = palette.accent
        let highlighted = palette.card.blended(withFraction: accent.alphaComponent * 0.45, of: accent.withAlphaComponent(1)) ?? palette.card
        tint.layer?.backgroundColor = (isDragHighlighted ? highlighted : palette.card).withAlphaComponent(0.8).cgColor
        ring.layer?.borderColor = (isDragHighlighted
            ? palette.primary.withAlphaComponent(0.7)
            : (palette.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.08))).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = palette.isDark ? 0 : 0.05
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ComposerTextView.carriesAttachments(sender.draggingPasteboard) else { return [] }
        isDragHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            onImageData?(data)
            return true
        }
        return false
    }
}

// MARK: - Attachments

/// Image thumbnails (56 pt, r8, remove ✕) and file chips above the editor.
final class ComposerAttachmentShelf: PaletteView {
    private let images = NSStackView()
    private let files = NSStackView()
    var onRemove: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        images.orientation = .horizontal
        images.spacing = 8
        files.orientation = .vertical
        files.alignment = .leading
        files.spacing = 4
        let stack = NSStackView(views: [images, files])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func setAttachments(_ attachments: [Attachment]) {
        images.arrangedSubviews.forEach { $0.removeFromSuperview() }
        files.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let remove: () -> Void = { [weak self] in self?.onRemove?(attachment.id) }
            if attachment.kind == .image {
                images.addArrangedSubview(AttachmentThumbnail(attachment, onRemove: remove))
            } else {
                files.addArrangedSubview(AttachmentFileChip(attachment, onRemove: remove))
            }
        }
        images.isHidden = images.arrangedSubviews.isEmpty
        files.isHidden = files.arrangedSubviews.isEmpty
        isHidden = attachments.isEmpty
    }
}

private final class AttachmentThumbnail: PaletteView {
    private let imageLayer = CALayer()
    private let remove: GhostIconButton

    init(_ attachment: Attachment, onRemove: @escaping () -> Void) {
        remove = GhostIconButton(symbol: Icon.close, size: 18, symbolSize: 8, toolTip: "Remove \(attachment.name)")
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = NSImage(contentsOfFile: attachment.path)
        layer?.addSublayer(imageLayer)
        remove.layer?.cornerRadius = 9
        remove.onClick = onRemove
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 56),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        toolTip = attachment.name
        setAccessibilityLabel(attachment.name)
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    override func applyPalette(_ palette: Palette) {
        layer?.borderColor = palette.border.composerFaded(0.8).cgColor
        layer?.backgroundColor = palette.muted.cgColor
        remove.restingTint = palette.foreground
        remove.layer?.backgroundColor = palette.background.withAlphaComponent(0.85).cgColor
    }
}

private final class AttachmentFileChip: PaletteView {
    private let icon = NSImageView()
    private let name = NSTextField.label("", size: Typography.smallSize)
    private let remove: GhostIconButton

    init(_ attachment: Attachment, onRemove: @escaping () -> Void) {
        remove = GhostIconButton(symbol: Icon.close, size: 18, symbolSize: 8, toolTip: "Remove \(attachment.name)")
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        icon.image = NSImage.symbol(Icon.file, size: 12)
        name.stringValue = attachment.name
        name.lineBreakMode = .byTruncatingMiddle
        remove.onClick = onRemove
        let stack = NSStackView(views: [icon, name, remove])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        toolTip = attachment.path
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.borderColor = palette.input.cgColor
        layer?.backgroundColor = (palette.isDark ? palette.input.composerFaded(0.32) : palette.popover).cgColor
        icon.contentTintColor = palette.mutedForeground
        name.textColor = palette.foreground
    }
}

// MARK: - Pending approval

/// The approval the running turn waits on, above the editor: kind title and detail, then
/// Decline, Approve (primary) and More (Cancel, Always allow this session).
final class ComposerApprovalPanel: PaletteView {
    private let icon = NSImageView()
    private let title = NSTextField.label("", size: Typography.rowSize, weight: .medium)
    private let detail = ComposerWrappingLabel.make(maximumLines: 4)
    private let reason = ComposerWrappingLabel.make(size: Typography.smallSize, maximumLines: 2)
    private let buttons = NSStackView()
    private let more = GhostIconButton(symbol: Icon.ellipsis, size: 24, symbolSize: 12, toolTip: "More approval options")
    private var request: ApprovalRequest?

    var onDecision: ((ApprovalDecision) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        detail.font = Typography.mono(Typography.smallSize)
        detail.lineBreakMode = .byCharWrapping
        detail.isSelectable = true
        buttons.orientation = .horizontal
        buttons.spacing = 6
        more.layer?.borderWidth = 1
        more.onClick = { [weak self] in self?.showMore() }
        let header = NSStackView(views: [icon, title, composerSpacer(), buttons])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.fillsWidth()
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = ComposerColumn([header, detail, reason], spacing: 4)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            header.heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyPalette(palette)
    }

    func configure(_ request: ApprovalRequest) {
        guard request != self.request else { return }
        self.request = request
        title.stringValue = request.kind.title
        setAccessibilityLabel(request.kind.title)
        icon.image = NSImage.symbol(Self.symbol(for: request.kind), size: 13)
        detail.stringValue = request.detail.isEmpty ? request.kind.title : request.detail
        reason.stringValue = request.reason ?? ""
        reason.isHidden = request.reason?.isEmpty ?? true
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for decision in request.options where decision == .decline || decision == .accept {
            let button = TextButton(decision.title, variant: decision == .accept ? .primary : .outline, size: .xs)
            button.onClick = { [weak self] in self?.onDecision?(decision) }
            buttons.addArrangedSubview(button)
        }
        if request.options.contains(where: { $0 != .decline && $0 != .accept }) {
            buttons.addArrangedSubview(more)
        }
    }

    static func symbol(for kind: ApprovalKind) -> String {
        switch kind {
        case .command: Icon.terminal
        case .fileChange: Icon.squarePenFile
        case .fileRead: Icon.eye
        case .permission: Icon.wrench
        case .other: Icon.shieldQuestion
        }
    }

    private func showMore() {
        guard let request else { return }
        let menu = NSMenu()
        for decision in request.options where decision != .decline && decision != .accept {
            let item = NSMenuItem(title: decision.title, action: #selector(chooseMore(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = decision.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func chooseMore(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let decision = ApprovalDecision(rawValue: raw) else { return }
        onDecision?(decision)
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.warningForeground
        title.textColor = palette.foreground
        detail.textColor = palette.foreground
        reason.textColor = palette.mutedForeground
        more.layer?.borderColor = palette.input.cgColor
    }
}

// MARK: - Pending user input

/// The agent's question above the editor: header chip, count, dismiss, the question and its
/// options (radio or checkbox, label, description, 1–9 hint).
final class ComposerQuestionPanel: PaletteView {
    private let header = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let headerChip = PaletteView()
    private let count = NSTextField.label("", size: Typography.smallSize)
    private let dismiss = GhostIconButton(symbol: Icon.close, size: 24, symbolSize: 11, toolTip: "Dismiss question without answering")
    private let question = ComposerWrappingLabel.make()
    private let options = ComposerColumn()

    var onToggleOption: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerChip.layer?.cornerRadius = Radius.sm
        header.translatesAutoresizingMaskIntoConstraints = false
        headerChip.addSubview(header)
        dismiss.onClick = { [weak self] in self?.onDismiss?() }
        let top = NSStackView(views: [headerChip, composerSpacer(), count, dismiss])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        top.fillsWidth()
        let stack = ComposerColumn([top, question, options], spacing: 8)
        stack.setSpacing(6, after: question)
        addSubview(stack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerChip.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: headerChip.trailingAnchor, constant: -6),
            header.centerYAnchor.constraint(equalTo: headerChip.centerYAnchor),
            headerChip.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            top.heightAnchor.constraint(equalToConstant: 24),
        ])
        applyPalette(palette)
    }

    func configure(question model: UserInputQuestion, index: Int, total: Int, selected: Set<String>, enabled: Bool) {
        header.stringValue = model.header
        count.stringValue = "\(index + 1)/\(total)"
        count.isHidden = total < 2
        question.stringValue = model.question
        options.removeAll()
        for (offset, option) in model.options.enumerated() {
            let row = QuestionOptionRow(option: option, index: offset, multiple: model.allowsMultiple, checked: selected.contains(option.label))
            row.isEnabled = enabled
            row.onClick = { [weak self] in self?.onToggleOption?(offset) }
            options.add(row)
        }
    }

    override func applyPalette(_ palette: Palette) {
        headerChip.layer?.backgroundColor = palette.foreground.withAlphaComponent(0.06).cgColor
        header.textColor = palette.mutedForeground
        count.textColor = palette.mutedForeground
        question.textColor = palette.foreground.withAlphaComponent(0.85)
    }
}

private final class QuestionOptionRow: InteractiveView {
    private let radio = ComposerRadioMark()
    private let label = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let detail = ComposerWrappingLabel.make(size: Typography.tinySize)
    private let checked: Bool
    private let multiple: Bool

    init(option: UserInputOption, index: Int, multiple: Bool, checked: Bool) {
        self.checked = checked
        self.multiple = multiple
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        radio.isChecked = checked
        if multiple { radio.layer?.cornerRadius = Radius.sm }
        label.stringValue = option.label
        detail.stringValue = option.description ?? ""
        detail.isHidden = option.description == nil || option.description == option.label
        let texts = ComposerColumn([label, detail], spacing: 2)
        texts.setContentHuggingPriority(.init(1), for: .horizontal)
        texts.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let kbd = KbdView("\(index + 1)")
        kbd.isHidden = index >= 9
        let row = NSStackView(views: [radio, texts, kbd])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.fillsWidth()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            radio.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            kbd.widthAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityRole(multiple ? .checkBox : .radioButton)
        setAccessibilityLabel(option.label)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered && !checked && isEnabled ? palette.muted.composerFaded(0.3) : .clear).cgColor
        label.textColor = checked ? palette.foreground : palette.foreground.withAlphaComponent(0.7)
        detail.textColor = palette.secondaryLabel
        alphaValue = isEnabled ? 1 : 0.5
    }
}

// MARK: - Draft hero

/// An inline link-like button: medium weight, underline on hover.
final class ComposerInlineButton: InteractiveView {
    enum Tone {
        case muted
        case picker
    }

    private let label = NSTextField.label()
    private let tone: Tone
    private let font: NSFont

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            applyPalette(palette)
        }
    }

    /// The popup the button opens is showing (underlined like hover).
    var isOpen = false {
        didSet { applyPalette(palette) }
    }

    init(_ title: String, tone: Tone, font: NSFont) {
        self.tone = tone
        self.font = font
        super.init(frame: .zero)
        label.font = font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
        self.title = title
    }

    override var firstBaselineAnchor: NSLayoutYAxisAnchor { label.firstBaselineAnchor }
    override var lastBaselineAnchor: NSLayoutYAxisAnchor { label.lastBaselineAnchor }
    override var firstBaselineOffsetFromTop: CGFloat { label.firstBaselineOffsetFromTop }
    override var lastBaselineOffsetFromBottom: CGFloat { label.lastBaselineOffsetFromBottom }

    override func applyPalette(_ palette: Palette) {
        let color: NSColor = switch tone {
        case .muted: isHovered ? palette.foreground : palette.mutedForeground
        case .picker: palette.foreground
        }
        let underline = isHovered || isOpen
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0,
            .underlineColor: color.withAlphaComponent(0.6),
        ])
    }
}

/// The headline above a draft's composer: "What should we build in <project>?" with the project
/// combobox and "or start without a project"; "What should we work on?" for scratch drafts and
/// when no project exists yet.
final class DraftHeroView: PaletteView {
    enum Mode: Equatable {
        case project(String)
        case scratch
        case noProjects
    }

    private let stack = ComposerColumn(spacing: 8)
    private var labels: [NSTextField] = []
    private(set) var projectButton: ComposerInlineButton?
    private var mode: Mode?

    var onProjectPicker: ((ComposerInlineButton) -> Void)?
    var onStartWithoutProject: (() -> Void)?
    var onAddProject: (() -> Void)?

    static let headlineFont = Typography.ui(24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.centersViews = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    func configure(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        stack.removeAll()
        labels = []
        projectButton = nil
        switch mode {
        case let .project(name):
            let lead = headline("What should we build in")
            let button = ComposerInlineButton(name, tone: .picker, font: Typography.ui(24, weight: .medium))
            button.toolTip = name
            button.onClick = { [weak self, weak button] in
                guard let button else { return }
                self?.onProjectPicker?(button)
            }
            projectButton = button
            let line = NSStackView(views: [lead, button, headline("?")])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 0
            line.setCustomSpacing(7, after: lead)
            stack.add(line)
            let link = ComposerInlineButton("or start without a project", tone: .muted, font: Typography.ui(Typography.bodySize, weight: .medium))
            link.onClick = { [weak self] in self?.onStartWithoutProject?() }
            stack.add(link)
        case .scratch:
            stack.add(headline("What should we work on?"))
            let button = ComposerInlineButton("No project", tone: .picker, font: Typography.ui(Typography.bodySize, weight: .medium))
            button.onClick = { [weak self, weak button] in
                guard let button else { return }
                self?.onProjectPicker?(button)
            }
            projectButton = button
            stack.add(button)
        case .noProjects:
            stack.add(headline("What should we work on?"))
            let description = NSTextField.label("Add a project, or start without one.", size: Typography.bodySize)
            labels.append(description)
            stack.add(description)
            let add = TextButton("Add project", symbol: Icon.plus, variant: .primary, size: .sm)
            add.onClick = { [weak self] in self?.onAddProject?() }
            stack.setSpacing(16, after: description)
            stack.add(add)
        }
        applyPalette(palette)
    }

    private func headline(_ text: String) -> NSTextField {
        let label = NSTextField.label(text, size: 24)
        label.font = Self.headlineFont
        labels.append(label)
        return label
    }

    override func applyPalette(_ palette: Palette) {
        for label in labels {
            label.textColor = label.font?.pointSize == 24 ? palette.foreground : palette.mutedForeground
        }
    }
}

// MARK: - Context strip

/// The row under a draft's composer: Workspace ("Current checkout" / "New worktree") on the
/// left, the branch on the right (read-only for the current checkout, the worktree's base
/// ref otherwise).
final class DraftContextStrip: PaletteView {
    let workspaceChip = ComposerChip(size: .context)
    let branchChip = ComposerChip(size: .context)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [workspaceChip, composerSpacer(), branchChip])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.fillsWidth()
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        workspaceChip.toolTip = "Workspace"
        branchChip.toolTip = "Branch"
    }

    func configure(usesWorktree: Bool, branchLabel: String) {
        workspaceChip.configure(
            title: usesWorktree ? "New worktree" : "Current checkout",
            image: NSImage.symbol(usesWorktree ? Icon.folderGit : Icon.folder, size: 11)
        )
        branchChip.configure(title: branchLabel, image: NSImage.symbol(Icon.gitBranch, size: 11))
        branchChip.isInteractive = usesWorktree
        branchChip.toolTip = usesWorktree ? "Base branch for the new worktree" : "Current branch"
    }
}
