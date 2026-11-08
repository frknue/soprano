import AppKit

/// Building blocks of the settings pages, ported from Soprano Agents'
/// `SettingsForm`: a section is a title (`text-base font-semibold`) over a
/// grouped card (`rounded-xl border border-border/60 bg-card/40`, rows ruled
/// off by `border-border/50` hairlines); a row is title (+ reset) and a muted
/// description on the left, the control on the right.
@MainActor
struct SettingsForm {
    /// Width of the page column the rows fill.
    let width: CGFloat

    /// A titled group of rows; `note` is a muted line between the title and
    /// the group.
    func section(_ title: String?, note: String? = nil, _ rows: [NSView]) -> NSView {
        section(title, note: note, group: SettingsGroupView(rows: rows))
    }

    /// A section around an existing group, for rows that change in place.
    func section(_ title: String?, note: String? = nil, group: SettingsGroupView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if let title {
            let label = SettingsLabel(title, size: 16, weight: .semibold)
            let titleRow = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            titleRow.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor, constant: -16),
                label.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
                titleRow.heightAnchor.constraint(equalToConstant: 28),
                titleRow.widthAnchor.constraint(equalToConstant: width),
            ])
            stack.addArrangedSubview(titleRow)
        }
        if let note {
            let label = SettingsLabel(note, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
            label.preferredMaxLayoutWidth = width - 32
            let noteRow = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            noteRow.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor, constant: -16),
                label.topAnchor.constraint(equalTo: noteRow.topAnchor),
                label.bottomAnchor.constraint(equalTo: noteRow.bottomAnchor),
                noteRow.widthAnchor.constraint(equalToConstant: width),
            ])
            stack.addArrangedSubview(noteRow)
            if let previous = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(2, after: previous) }
        }
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(group)
        return stack
    }

    /// One row. `reset` shows the undo button after the title (only pass it
    /// when the value is not the default).
    func row(
        _ title: String,
        description: String? = nil,
        descriptionRole: ((Palette) -> NSColor)? = nil,
        titleRole: ((Palette) -> NSColor)? = nil,
        mono: Bool = false,
        reset: (() -> Void)? = nil,
        control: NSView? = nil
    ) -> SettingsRowView {
        SettingsRowView(
            title: title,
            description: description,
            descriptionRole: descriptionRole,
            titleRole: titleRole,
            mono: mono,
            reset: reset,
            control: control,
            width: width
        )
    }

    /// Controls side by side (keycaps + buttons, two buttons).
    func group(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// A read-only value on the right of a row.
    func value(_ text: String, mono: Bool = false) -> NSTextField {
        let label = SettingsLabel(text, size: mono ? Typography.rowSize : Typography.bodySize) { $0.mutedForeground }
        if mono { label.font = Typography.mono(Typography.rowSize) }
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func button(
        _ title: String,
        symbol: String? = nil,
        variant: SettingsButton.Variant = .outline,
        size: SettingsButton.Size = .sm,
        action: @escaping () -> Void
    ) -> SettingsButton {
        SettingsButton(title, symbol: symbol, variant: variant, size: size, handler: action)
    }
}

/// The grouped card of a section: rows separated by `border-border/50`
/// hairlines. `setRows` swaps the rows in place.
final class SettingsGroupView: PaletteView {
    private var dividers: [CALayer] = []
    private(set) var rows: [NSView] = []
    private var rowConstraints: [NSLayoutConstraint] = []

    init(rows: [NSView]) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.xl
        layer?.borderWidth = 1
        setRows(rows)
    }

    func setRows(_ newRows: [NSView]) {
        NSLayoutConstraint.deactivate(rowConstraints)
        rowConstraints.removeAll()
        for row in rows where !newRows.contains(where: { $0 === row }) {
            row.removeFromSuperview()
        }
        for divider in dividers { divider.removeFromSuperlayer() }
        dividers.removeAll()
        rows = newRows

        var previous: NSView?
        for row in newRows {
            row.translatesAutoresizingMaskIntoConstraints = false
            if row.superview !== self { addSubview(row) }
            rowConstraints += [
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor, constant: previous == nil ? 0 : 1),
            ]
            if previous != nil {
                let divider = CALayer()
                layer?.addSublayer(divider)
                dividers.append(divider)
            }
            previous = row
        }
        if let previous {
            rowConstraints.append(previous.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(rowConstraints)
        applyPalette(palette)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, divider) in dividers.enumerated() where index + 1 < rows.count {
            let row = rows[index + 1]
            divider.frame = NSRect(x: 0, y: row.frame.minY - 1, width: bounds.width, height: 1)
        }
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.card.withAlphaComponent(0.4).cgColor
        layer?.borderColor = palette.border.withAlphaComponent(palette.border.alphaComponent * 0.6).cgColor
        for divider in dividers {
            divider.backgroundColor = palette.border.withAlphaComponent(palette.border.alphaComponent * 0.5).cgColor
        }
    }
}

/// `SettingsRow`: title (+ reset) and description on the left, control on
/// the right, `px-4 py-3`.
final class SettingsRowView: NSView {
    let titleLabel: SettingsLabel
    private(set) var descriptionLabel: SettingsLabel?

    init(
        title: String,
        description: String?,
        descriptionRole: ((Palette) -> NSColor)? = nil,
        titleRole: ((Palette) -> NSColor)? = nil,
        mono: Bool = false,
        reset: (() -> Void)? = nil,
        control: NSView?,
        width: CGFloat
    ) {
        titleLabel = SettingsLabel(title, size: Typography.bodySize, weight: .medium, role: titleRole ?? { $0.foreground })
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        if let reset {
            let button = GhostIconButton(symbol: Icon.undo, size: 20, symbolSize: 11, toolTip: "Reset to default")
            button.onClick = reset
            titleRow.addArrangedSubview(button)
        }

        let left = NSStackView(views: [titleRow])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 4
        let controlWidth = control.map { max($0.fittingSize.width, 0) } ?? 0
        let textWidth = width - 32 - (control == nil ? 0 : controlWidth + 32)
        // An empty description still gets its label, so a row that fills it
        // in later (notification permission) keeps its place.
        if let description {
            let label = SettingsLabel(description, size: Typography.smallSize, wrapping: true, role: descriptionRole ?? { $0.mutedForeground })
            if mono { label.font = Typography.mono(Typography.smallSize) }
            label.preferredMaxLayoutWidth = max(120, min(672, textWidth))
            label.isSelectable = true
            label.isHidden = description.isEmpty
            left.addArrangedSubview(label)
            descriptionLabel = label
        }
        left.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)
        var constraints = [
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            left.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            left.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
                left.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -32),
            ]
        } else {
            constraints.append(left.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16))
        }
        let fill = left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        fill.priority = .defaultLow
        constraints.append(fill)
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Replaces the description, hiding the line while it is empty.
    func setDescription(_ text: String) {
        descriptionLabel?.stringValue = text
        descriptionLabel?.isHidden = text.isEmpty
    }
}

/// A settings row whose content fills it from the left (an input with its
/// buttons, "Add Account"): `px-4`, at least 52 pt high.
final class SettingsActionsRowView: NSView {
    init(views: [NSView], fills: Bool = false) {
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        if fills { stack.distribution = .fill }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            fills
                ? stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
                : stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

/// The page column inside the scroll view: sections stacked with `gap-8`,
/// centered, `py-8`. Frame-sized (`fit(to:)`), so a long page never becomes
/// the window's minimum size.
final class SettingsDocumentView: NSView {
    private let stack = NSStackView()
    private var widthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setSections(_ sections: [NSView], width: CGFloat) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections { stack.addArrangedSubview(section) }
        widthConstraint?.isActive = false
        widthConstraint = stack.widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
    }

    /// Sizes the document to the clip width and the stack's height.
    func fit(to width: CGFloat) {
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 64
        setFrameSize(NSSize(width: width, height: height))
        layoutSubtreeIfNeeded()
    }

    func field(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier == identifier { return field }
            for subview in view.subviews {
                if let match = search(subview) { return match }
            }
            return nil
        }
        return search(self)
    }
}
