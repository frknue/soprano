import AppKit

// Soprano Agents' form controls (`Shell/FormControls.swift`, the
// Teammate dialog's text box and `PlaceholderTextView`, the Statistics
// segmented control), ported for the Automations page and its editor.

/// Input: a single-line field in a rounded `border-input` box (`bg-background`,
/// dark `bg-input/32`). `onCommit` runs on Return and when editing ends with a changed value.
final class AutoUIInputField: PaletteView, NSTextFieldDelegate {
    let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    /// Return / Escape inside the field; return true when handled.
    var onCommand: ((Selector) -> Bool)?
    /// Draws the error ring (an invalid value).
    var isInvalid = false {
        didSet { applyPalette(palette) }
    }
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
        // Return in an untouched field must not write the shown (often default) value.
        valueAtBeginEditing = value
        applyPalette(palette)
    }

    var placeholder: String = "" {
        didSet { applyPalette(palette) }
    }

    var stringValue: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            valueAtBeginEditing = newValue
        }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.background).cgColor
        layer?.borderColor = (isInvalid ? palette.error
            : isEditing ? palette.primary.withAlphaComponent(0.7) : palette.input).cgColor
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: palette.placeholder,
            .font: field.font ?? Typography.ui(),
        ])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = palette.foreground
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
final class AutoUISwitchControl: InteractiveView {
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
        translatesAutoresizingMaskIntoConstraints = false
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

    override func accessibilityValue() -> Any? { isOn }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// One entry of an `AutoUISelectButton` menu.
struct AutoUISelectOption: Equatable {
    var title: String
    var value: String
    /// Draws a separator above this entry.
    var separatorBefore = false
    var toolTip: String?
    var isEnabled = true
}

/// Select trigger (`size="sm"`, outline look): the selected label and an up/down
/// chevron; a click opens a native menu with the options, the selected one checked.
final class AutoUISelectButton: InteractiveView {
    private let label = NSTextField.label("", size: Typography.bodySize)
    private let chevron = NSImageView()
    private(set) var options: [AutoUISelectOption]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?

    var selectedTitle: String { label.stringValue }

    init(options: [AutoUISelectOption], selected: String, width: CGFloat?, accessibilityLabel: String, monospaced: Bool = false) {
        self.options = options
        self.selectedValue = selected
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        if monospaced { label.font = Typography.mono(Typography.rowSize) }
        label.stringValue = options.first { $0.value == selected }?.title ?? selected
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage.symbol("chevron.up.chevron.down", size: 10, weight: .medium)
        for view in [label, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ]
        if let width { constraints.append(widthAnchor.constraint(equalToConstant: width)) }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabel)
        onClick = { [weak self] in self?.showMenu() }
        applyPalette(palette)
    }

    /// Replaces the options and the selection without calling `onSelect`.
    func setOptions(_ options: [AutoUISelectOption], selected: String) {
        self.options = options
        select(selected)
    }

    /// Selects `value` without calling `onSelect`.
    func select(_ value: String) {
        selectedValue = value
        label.stringValue = options.first { $0.value == value }?.title ?? value
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

    /// The menu a click opens: the options, the selected one checked.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            if option.separatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            item.state = option.value == selectedValue ? .on : .off
            item.toolTip = option.toolTip
            item.isEnabled = option.isEnabled
            menu.addItem(item)
        }
        menu.appearance = PaletteCenter.shared.palette.appearance
        menu.minimumWidth = bounds.width
        return menu
    }

    private func showMenu() {
        guard isEnabled else { return }
        let menu = makeMenu()
        let selectedItem = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selectedItem, at: NSPoint(x: 0, y: bounds.height - 4), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    /// Picks `value` as a menu choice would (calls `onSelect` when it changed).
    func choose(value: String) {
        guard value != selectedValue, options.contains(where: { $0.value == value }) else { return }
        select(value)
        onSelect?(value)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        choose(value: value)
    }
}

/// A label whose color follows the palette (`role` picks the token), single-line truncating
/// or wrapping.
final class AutoUIThemedLabel: NSTextField {
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

/// A text view that draws a placeholder while empty.
class AutoUIPlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Typography.ui(),
            .foregroundColor: PaletteCenter.shared.palette.placeholder,
            .paragraphStyle: paragraph,
        ]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(x: x, y: textContainerInset.height, width: max(0, bounds.width - x * 2), height: bounds.height)
        NSAttributedString(string: placeholder, attributes: attributes).draw(in: rect)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// A multi-line text box a few lines tall that scrolls, in the input box style
/// (`border-input`, `bg-background`, dark `bg-input/32`): the Teammate dialog's Instructions.
final class AutoUITextBox: PaletteView {
    let textView: AutoUIPlaceholderTextView
    private let scrollView = NSScrollView()
    private var isFocused = false

    var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue }
    }

    init(textView: AutoUIPlaceholderTextView, width: CGFloat) {
        self.textView = textView
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 88)
        textView.font = Typography.ui(Typography.bodySize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        applyPalette(palette)
    }

    /// Rings the box while its text view has the keyboard.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.background).cgColor
        layer?.borderColor = (isFocused ? palette.primary.withAlphaComponent(0.7) : palette.input).cgColor
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        textView.typingAttributes = [.font: textView.font ?? Typography.ui(), .foregroundColor: palette.foreground]
        textView.selectedTextAttributes = [.backgroundColor: palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22)]
        textView.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}

/// Segmented control: a muted `rounded-lg` track with the selected segment raised
/// (Soprano Agents' Statistics period / metric control).
final class AutoUISegmentedControl: PaletteView {
    var onSelect: ((Int) -> Void)?
    private var segments: [AutoUISegment] = []

    var selectedIndex: Int {
        didSet {
            for (index, segment) in segments.enumerated() { segment.isSelected = index == selectedIndex }
        }
    }

    init(titles: [String], selectedIndex: Int, accessibilityLabel: String) {
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (index, title) in titles.enumerated() {
            let segment = AutoUISegment(title: title)
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
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            // As wide as its segments wherever it sits.
            widthAnchor.constraint(equalToConstant: ceil(stack.fittingSize.width) + 4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
        applyPalette(palette)
    }

    var segmentCount: Int { segments.count }

    func setEnabled(_ isEnabled: Bool, forSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].isEnabled = isEnabled
    }

    func isEnabled(forSegment index: Int) -> Bool {
        segments.indices.contains(index) && segments[index].isEnabled
    }

    override func accessibilityChildren() -> [Any]? { segments }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(0.06).cgColor
    }
}

final class AutoUISegment: InteractiveView {
    private let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)

    var isSelected = false {
        didSet { applyPalette(palette) }
    }

    init(title: String) {
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
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isSelected ? palette.popover : isHovered && isEnabled ? palette.accent : .clear).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = palette.input.withAlphaComponent(palette.input.alphaComponent * 0.6).cgColor
        label.textColor = !isEnabled ? palette.mutedForeground.withAlphaComponent(0.45)
            : isSelected || isHovered ? palette.foreground : palette.mutedForeground
        alphaValue = isPressed ? 0.85 : 1
    }

    override func accessibilityValue() -> Any? { isSelected }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}
