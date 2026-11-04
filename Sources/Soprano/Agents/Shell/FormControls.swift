import AppKit

/// Input: a single-line field in a rounded `border-input` box (`bg-background`,
/// dark `bg-input/32`). `onCommit` runs on Return and when editing ends with a changed value.
final class InputField: PaletteView, NSTextFieldDelegate {
    let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    /// Return / Escape inside the field; return true when handled.
    var onCommand: ((Selector) -> Bool)?
    private var isEditing = false
    private var valueAtBeginEditing = ""

    init(value: String = "", placeholder: String = "", height: CGFloat = 32, monospaced: Bool = false) {
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        field.stringValue = value
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.font = monospaced ? Typography.mono(Typography.rowSize) : Typography.ui(Typography.bodySize)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        self.placeholder = placeholder
        applyPalette(palette)
    }

    var placeholder: String = "" {
        didSet { applyPalette(palette) }
    }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.background).cgColor
        layer?.borderColor = (isEditing ? palette.primary.withAlphaComponent(0.7) : palette.input).cgColor
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: palette.placeholder,
            .font: field.font ?? Typography.ui(),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        valueAtBeginEditing = field.stringValue
        applyPalette(palette)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        applyPalette(palette)
        if field.stringValue != valueAtBeginEditing {
            valueAtBeginEditing = field.stringValue
            onCommit?(field.stringValue)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if onCommand?(commandSelector) == true { return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if field.stringValue != valueAtBeginEditing {
                valueAtBeginEditing = field.stringValue
                onCommit?(field.stringValue)
            }
            return true
        }
        return false
    }
}

/// Switch: 30×18 track (`bg-primary` on, `bg-input` off) with a 14 pt thumb.
final class SwitchControl: InteractiveView {
    private let thumb = CALayer()
    var onToggle: ((Bool) -> Void)?

    var isOn: Bool {
        didSet { applyPalette(palette) }
    }

    init(isOn: Bool, label: String) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 18))
        layer?.cornerRadius = 9
        thumb.cornerRadius = 7
        layer?.addSublayer(thumb)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        onClick = { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
            onToggle?(self.isOn)
        }
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = NSRect(x: isOn ? 14 : 2, y: 2, width: 14, height: 14)
        CATransaction.commit()
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isOn ? palette.primary : palette.input).cgColor
        thumb.backgroundColor = (palette.isDark && !isOn ? palette.mutedForeground : palette.background).cgColor
        thumb.shadowOpacity = 0.12
        thumb.shadowRadius = 1
        thumb.shadowOffset = CGSize(width: 0, height: -0.5)
        alphaValue = isEnabled ? 1 : 0.64
        needsLayout = true
    }
}

/// One entry of a `SelectButton` menu.
struct SelectOption: Equatable {
    var title: String
    var value: String
    /// Draws a separator above this entry.
    var separatorBefore = false
}

/// Select trigger (`size="sm"`, outline look): the selected label and an up/down
/// chevron; a click opens a native menu with the options, the selected one checked.
final class SelectButton: InteractiveView {
    private let label = NSTextField.label("", size: Typography.bodySize)
    private let chevron = NSImageView()
    let options: [SelectOption]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?

    init(options: [SelectOption], selected: String, width: CGFloat, accessibilityLabel: String) {
        self.options = options
        self.selectedValue = selected
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        label.stringValue = options.first { $0.value == selected }?.title ?? selected
        chevron.image = NSImage.symbol("chevron.up.chevron.down", size: 10, weight: .medium)
        for view in [label, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabel)
        onClick = { [weak self] in self?.showMenu() }
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let fill = isHovered ? palette.accent : (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.popover)
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = palette.input.cgColor
        label.textColor = isEnabled ? palette.foreground : palette.mutedForeground
        chevron.contentTintColor = palette.mutedForeground
        alphaValue = isEnabled ? 1 : 0.64
    }

    private func showMenu() {
        guard isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selectedItem: NSMenuItem?
        for option in options {
            if option.separatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            item.state = option.value == selectedValue ? .on : .off
            if item.state == .on { selectedItem = item }
            menu.addItem(item)
        }
        menu.appearance = PaletteCenter.shared.palette.appearance
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: selectedItem, at: NSPoint(x: 0, y: bounds.height - 4), in: self)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, value != selectedValue else { return }
        selectedValue = value
        label.stringValue = sender.title
        onSelect?(value)
    }
}

/// A label whose color follows the palette (`role` picks the token), single-line truncating
/// or wrapping.
final class ThemedLabel: NSTextField {
    var role: (Palette) -> NSColor {
        didSet { textColor = role(PaletteCenter.shared.palette) }
    }

    init(_ text: String = "", size: CGFloat = Typography.bodySize, weight: NSFont.Weight = .regular, wrapping: Bool = false, role: @escaping (Palette) -> NSColor = { $0.foreground }) {
        self.role = role
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        isBezeled = false
        font = Typography.ui(size, weight: weight)
        stringValue = text
        if wrapping {
            lineBreakMode = .byWordWrapping
            maximumNumberOfLines = 0
            cell?.wraps = true
            setContentCompressionResistancePriority(.required, for: .vertical)
        } else {
            lineBreakMode = .byTruncatingTail
            maximumNumberOfLines = 1
            cell?.truncatesLastVisibleLine = true
        }
        textColor = role(PaletteCenter.shared.palette)
        PaletteCenter.shared.addObserver(self) { [weak self] palette in
            guard let self else { return }
            textColor = self.role(palette)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
