import AppKit

/// Building blocks of the settings pages:
/// `SettingsSection` (title `text-base font-semibold`, then a grouped card `rounded-xl border
/// border-border/60 bg-card/40` with dividers) and `SettingsRow` (title `text-sm font-medium`,
/// reset button, description `text-xs text-muted-foreground`, control on the right).
@MainActor
struct SettingsForm {
    /// Width of the page column the rows fill.
    let width: CGFloat

    /// A titled group of rows; `note` is a muted line between the title and the group.
    func section(_ title: String?, note: String? = nil, _ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if let title {
            let label = ThemedLabel(title, size: 16, weight: .semibold)
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
            let label = ThemedLabel(note, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
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
        let group = SettingsGroupView(rows: rows)
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(group)
        return stack
    }

    /// One row. `reset` shows the undo button after the title (only pass it when non-default).
    func row(
        _ title: String,
        description: String? = nil,
        descriptionRole: ((Palette) -> NSColor)? = nil,
        mono: Bool = false,
        reset: (() -> Void)? = nil,
        control: NSView? = nil
    ) -> NSView {
        SettingsRowView(
            title: title,
            description: description,
            descriptionRole: descriptionRole,
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
    func value(_ text: String, mono: Bool = false) -> NSView {
        let label = ThemedLabel(text, size: mono ? Typography.rowSize : Typography.bodySize) { $0.mutedForeground }
        if mono { label.font = Typography.mono(Typography.rowSize) }
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func select(_ options: [SelectOption], selected: String, width: CGFloat, label: String, onSelect: @escaping (String) -> Void) -> SelectButton {
        let button = SelectButton(options: options, selected: selected, width: width, accessibilityLabel: label)
        button.onSelect = onSelect
        return button
    }

    func toggle(_ isOn: Bool, label: String, enabled: Bool = true, onToggle: @escaping (Bool) -> Void) -> SwitchControl {
        let control = SwitchControl(isOn: isOn, label: label)
        control.isEnabled = enabled
        control.onToggle = onToggle
        return control
    }

    func field(_ value: String, placeholder: String, width: CGFloat, identifier: String, mono: Bool = false, onCommit: @escaping (String) -> Void) -> InputField {
        let field = InputField(value: value, placeholder: placeholder, height: 30, monospaced: mono)
        field.field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.onCommit = onCommit
        return field
    }

    func button(_ title: String, symbol: String? = nil, variant: TextButton.Variant = .outline, size: TextButton.Size = .sm, action: @escaping () -> Void) -> TextButton {
        let button = TextButton(title, symbol: symbol, variant: variant, size: size)
        button.onClick = action
        return button
    }
}

/// The grouped card of a section: rows separated by `border-border/50` hairlines.
final class SettingsGroupView: PaletteView {
    private var dividers: [CALayer] = []
    private let rows: [NSView]

    init(rows: [NSView]) {
        self.rows = rows
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.xl
        layer?.borderWidth = 1
        var previous: NSView?
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor, constant: previous == nil ? 0 : 1),
            ])
            if previous != nil {
                let divider = CALayer()
                layer?.addSublayer(divider)
                dividers.append(divider)
            }
            previous = row
        }
        if let previous {
            previous.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, divider) in dividers.enumerated() {
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

/// `SettingsRow`: title (+ reset) and description on the left, control on the right, `px-4 py-3`.
final class SettingsRowView: NSView {
    init(
        title: String,
        description: String?,
        descriptionRole: ((Palette) -> NSColor)?,
        mono: Bool,
        reset: (() -> Void)?,
        control: NSView?,
        width: CGFloat
    ) {
        super.init(frame: .zero)
        let titleLabel = ThemedLabel(title, size: Typography.bodySize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
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
        if let description, !description.isEmpty {
            let label = ThemedLabel(description, size: Typography.smallSize, wrapping: true, role: descriptionRole ?? { $0.mutedForeground })
            if mono { label.font = Typography.mono(Typography.smallSize) }
            label.preferredMaxLayoutWidth = max(120, min(672, textWidth))
            label.isSelectable = true
            left.addArrangedSubview(label)
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
}
