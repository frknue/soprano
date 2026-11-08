import AppKit

// MARK: - Surface

/// The composer surface: r16 glass card (card / raised surface at 80% over a blur), a 1 pt
/// outline (black 8% light, white 5% dark), the composer shadow in light mode.
final class ComposerSurfaceView: PaletteView {
    private let blur = NSVisualEffectView()
    private let tint = PaletteView()
    /// Drawn over the content, so it must never take a click (`ComposerOutlineView`).
    private let ring = ComposerOutlineView()
    let content = ComposerColumn()

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
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        blur.appearance = palette.appearance
        tint.layer?.backgroundColor = palette.card.withAlphaComponent(0.8).cgColor
        ring.layer?.borderColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.05 : 0.08).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = palette.isDark ? 0 : 0.05
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// The composer's outline: a full-size layer on top of the content that only draws. It is
/// transparent to the mouse, so clicks reach the editor, chips and buttons underneath.
private final class ComposerOutlineView: PaletteView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    private let more = GhostIconButton(symbol: ComposerIcon.ellipsis, size: 24, symbolSize: 12, toolTip: "More approval options")
    private var request: ApprovalRequest?

    /// The option a button or the More menu picked.
    var onOption: ((ApprovalOption) -> Void)?

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
        for (option, title) in [(request.options.declineOption, "Decline"), (request.options.approveOption, "Approve")] {
            guard let option else { continue }
            let button = TextButton(title, variant: title == "Approve" ? .primary : .outline, size: .xs)
            button.onClick = { [weak self] in self?.onOption?(option) }
            buttons.addArrangedSubview(button)
        }
        if !request.options.moreOptions.isEmpty {
            buttons.addArrangedSubview(more)
        }
    }

    static func symbol(for kind: ApprovalKind) -> String {
        switch kind {
        case .command: Icon.terminal
        case .fileChange: Icon.squarePenFile
        case .fileRead: Icon.eye
        case .other: Icon.shieldQuestion
        }
    }

    private func showMore() {
        guard let request else { return }
        let menu = NSMenu()
        for option in request.options.moreOptions {
            let item = NSMenuItem(title: option.name, action: #selector(chooseMore(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func chooseMore(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let option = request?.options.first(where: { $0.id == id }) else { return }
        onOption?(option)
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
    private let dismiss = GhostIconButton(symbol: ComposerIcon.close, size: 24, symbolSize: 11, toolTip: "Dismiss question without answering")
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
        headerChip.isHidden = model.header.isEmpty
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

// MARK: - Plan

/// The plan the agent keeps for its task, at the top of the composer while it has open steps
/// or a turn runs: "Plan  2 of 5 done" with the current step, a chevron that lists every step
/// (done ✓, current ◌, pending ○).
final class ComposerPlanPanel: PaletteView {
    private let icon = NSImageView()
    private let title = NSTextField.label("Plan", size: Typography.rowSize, weight: .medium)
    private let progress = NSTextField.label("", size: Typography.smallSize)
    private let current = NSTextField.label("", size: Typography.rowSize)
    private let toggle = GhostIconButton(symbol: Icon.chevronDown, size: 24, symbolSize: 11, toolTip: "Show every step")
    private let steps = ComposerColumn(spacing: 2)
    private var entries: [AgentChatPlanEntry] = []

    /// Every step shows, not just the current one.
    private(set) var isExpanded = false
    /// The panel's height changed (expanded or collapsed).
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage.symbol(TimelineIcon.plan, size: 13)
        icon.imageScaling = .scaleNone
        current.lineBreakMode = .byTruncatingTail
        current.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        toggle.onClick = { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false)) }
        let header = NSStackView(views: [icon, title, progress, current, composerSpacer(), toggle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setCustomSpacing(10, after: progress)
        header.fillsWidth()
        let stack = ComposerColumn([header, steps], spacing: 4)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            header.heightAnchor.constraint(equalToConstant: 24),
        ])
        steps.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Plan")
        applyPalette(palette)
    }

    func configure(_ entries: [AgentChatPlanEntry]) {
        guard entries != self.entries else { return }
        self.entries = entries
        let done = entries.filter { $0.status == .completed }.count
        progress.stringValue = "\(done) of \(entries.count) done"
        let step = entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending }
        current.stringValue = step?.content ?? ""
        steps.removeAll()
        for entry in entries {
            steps.add(PlanStepRow(entry))
        }
        applyPalette(palette)
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        steps.isHidden = !expanded
        current.isHidden = expanded
        toggle.setSymbol(expanded ? ComposerIcon.chevronUp : Icon.chevronDown, size: 11)
        toggle.toolTip = expanded ? "Show the current step" : "Show every step"
        onResize?()
    }

    override func applyPalette(_ palette: Palette) {
        icon.contentTintColor = palette.mutedForeground
        title.textColor = palette.foreground
        progress.textColor = palette.mutedForeground
        current.textColor = palette.secondaryLabel
    }
}

/// One step of the plan: its status mark and text.
private final class PlanStepRow: PaletteView {
    private let mark = NSImageView()
    private let label = ComposerWrappingLabel.make(size: Typography.rowSize, maximumLines: 2)
    private let status: AgentChatPlanEntry.Status

    init(_ entry: AgentChatPlanEntry) {
        status = entry.status
        super.init(frame: .zero)
        let symbol = switch entry.status {
        case .completed: Icon.circleCheck
        case .inProgress: Icon.circleDashed
        case .pending: "circle"
        }
        mark.image = NSImage.symbol(symbol, size: 12)
        mark.imageScaling = .scaleNone
        label.stringValue = entry.content
        for view in [mark, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            mark.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        switch status {
        case .completed:
            mark.contentTintColor = palette.successForeground
            label.textColor = palette.mutedForeground
        case .inProgress:
            mark.contentTintColor = palette.infoForeground
            label.textColor = palette.foreground
        case .pending:
            mark.contentTintColor = palette.mutedForeground.withAlphaComponent(0.7)
            label.textColor = palette.secondaryLabel
        }
    }
}
