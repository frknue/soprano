import AppKit

// Soprano Agents' settings form controls (`Shell/FormControls.swift`,
// `TextButton`, the statistics segmented control), ported as AppKit controls
// (`NSControl` / `NSButton` / `NSPopUpButton`) so the settings screen keeps
// target/action, Full Keyboard Access and accessibility.

/// Agents' `ThemedLabel`: a label whose color follows the palette (`role`
/// picks the token), single-line truncating or wrapping.
final class SettingsLabel: NSTextField {
    var role: (Palette) -> NSColor {
        didSet { textColor = role(PaletteCenter.shared.palette) }
    }

    init(
        _ text: String = "",
        size: CGFloat = Typography.bodySize,
        weight: NSFont.Weight = .regular,
        wrapping: Bool = false,
        role: @escaping (Palette) -> NSColor = { $0.foreground }
    ) {
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

/// Agents' `SwitchControl` (30×18 track, `bg-primary` on, `bg-input` off,
/// 14 pt thumb) as an `NSControl`: a click or Space flips `state` and sends
/// the action.
final class SettingsSwitch: NSControl {
    var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
            setAccessibilityValue(state == .on)
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    init(isOn: Bool, label: String, target: AnyObject? = nil, action: Selector? = nil) {
        state = isOn ? .on : .off
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 18))
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(isOn)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 18) }
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var acceptsFirstResponder: Bool { canBecomeKeyView }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let isOn = state == .on
        let alpha: CGFloat = isEnabled ? 1 : 0.64
        (isOn ? palette.primary : palette.input).withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let thumb = NSRect(x: isOn ? 14 : 2, y: 2, width: 14, height: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (palette.isDark && !isOn ? palette.mutedForeground : palette.background).withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: thumb).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let up = window?.nextEvent(matching: [.leftMouseUp]) else { return }
        guard bounds.contains(convert(up.locationInWindow, from: nil)) else { return }
        toggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }
}

/// Agents' `SelectButton` (`size="sm"`, outline look): the selected title and
/// an up/down chevron; a click opens the native menu, the selected entry
/// checked. An `NSPopUpButton`, so keyboard and accessibility work as usual.
final class SettingsSelectButton: NSPopUpButton {
    private let width: CGFloat
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// `separatorAfterFirst` sets the first entry apart, as Agents' theme
    /// menu does with "Follow Soprano". Entries carry their value as
    /// `representedObject`.
    init(options: [(title: String, value: String)], selected: String, width: CGFloat, accessibilityLabel: String, separatorAfterFirst: Bool = false) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30), pullsDown: false)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        font = Typography.ui(Typography.bodySize)
        removeAllItems()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.value
            menu?.addItem(item)
            if index == 0, separatorAfterFirst, options.count > 1 { menu?.addItem(.separator()) }
        }
        if let item = itemArray.first(where: { $0.representedObject as? String == selected }) {
            select(item)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityLabel(accessibilityLabel)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The value of the chosen entry.
    var selectedValue: String? { selectedItem?.representedObject as? String }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 30) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Radius.lg, yRadius: Radius.lg)
        let fill = isHovered ? palette.accent : (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.popover)
        fill.setFill()
        path.fill()
        palette.input.setStroke()
        path.lineWidth = 1
        path.stroke()

        let chevron = NSImage.symbol("chevron.up.chevron.down", size: 10, weight: .medium)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [palette.mutedForeground]))
        var chevronMinX = bounds.maxX - 9
        if let chevron {
            let size = chevron.size
            chevronMinX = bounds.maxX - 9 - size.width
            chevron.draw(
                in: NSRect(x: chevronMinX, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.64, respectFlipped: true, hints: nil
            )
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Typography.ui(Typography.bodySize),
            .foregroundColor: isEnabled ? palette.foreground : palette.mutedForeground,
            .paragraphStyle: paragraph,
        ]
        let title = titleOfSelectedItem ?? ""
        let height = ceil((title as NSString).size(withAttributes: attributes).height)
        (title as NSString).draw(
            in: NSRect(x: 10, y: floor((bounds.height - height) / 2), width: max(0, chevronMinX - 6 - 10), height: height),
            withAttributes: attributes
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Agents' `InputField`: a single-line field in a rounded `border-input` box
/// (`bg-background`, dark `bg-input/32`); the edge turns primary while it
/// edits. The owner sets the embedded `field`'s target/action.
final class SettingsInputField: PaletteView, NSTextFieldDelegate {
    let field = NSTextField()
    /// Called on every keystroke.
    var onChange: ((String) -> Void)?
    private var isEditing = false

    init(value: String = "", placeholder: String = "", width: CGFloat? = nil, height: CGFloat = 30, font: NSFont = Typography.ui(Typography.bodySize)) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
        field.font = font
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var constraints = [
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ]
        if let width { constraints.append(widthAnchor.constraint(equalToConstant: width)) }
        NSLayoutConstraint.activate(constraints)
        self.placeholder = placeholder
        applyPalette(palette)
    }

    var placeholder: String = "" {
        didSet { applyPalette(palette) }
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
        applyPalette(palette)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        applyPalette(palette)
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }
}

/// Agents' `TextButton` (outline, primary, ghost, destructive outline; xs
/// h24 / sm h28) as an `NSButton`. A `handler` makes the button its own
/// target, so per-row actions need no tag bookkeeping.
final class SettingsButton: NSButton {
    enum Variant {
        case primary
        case outline
        case ghost
        case destructiveOutline
    }

    enum Size {
        /// h24, text-xs.
        case xs
        /// h28, 13 pt.
        case sm

        var height: CGFloat { self == .xs ? 24 : 28 }
        var fontSize: CGFloat { self == .xs ? Typography.smallSize : Typography.rowSize }
        var padding: CGFloat { self == .xs ? 8 : 10 }
    }

    let variant: Variant
    let size: Size
    private let symbol: String?
    private var handler: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override var title: String {
        didSet {
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    init(_ title: String, symbol: String? = nil, variant: Variant = .outline, size: Size = .sm, handler: (() -> Void)? = nil) {
        self.variant = variant
        self.size = size
        self.symbol = symbol
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if handler != nil {
            target = self
            action = #selector(invokeHandler)
        }
        setAccessibilityLabel(title)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invokeHandler() {
        handler?()
    }

    private var titleFont: NSFont { Typography.ui(size.fontSize, weight: .medium) }
    private var symbolImage: NSImage? { symbol.flatMap { NSImage.symbol($0, size: size == .xs ? 12 : 14) } }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let symbolWidth = symbolImage.map { ceil($0.size.width) + 6 } ?? 0
        return NSSize(width: size.padding * 2 + symbolWidth + titleWidth, height: size.height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        var fill: NSColor = .clear
        var text = palette.foreground
        var border: NSColor?
        switch variant {
        case .primary:
            fill = isHovered ? palette.primary.mixed(with: palette.background, fraction: 0.1) : palette.primary
            text = palette.primaryForeground
        case .outline:
            fill = isHovered ? palette.accent : (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.popover)
            border = palette.input
        case .ghost:
            fill = isHovered ? palette.accent : .clear
        case .destructiveOutline:
            fill = isHovered ? palette.error.withAlphaComponent(0.08) : .clear
            border = palette.error.withAlphaComponent(0.4)
            text = palette.errorForeground
        }
        if !isEnabled {
            text = text.withAlphaComponent(0.5)
            if variant == .primary { fill = fill.withAlphaComponent(0.5) }
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.lg, yRadius: Radius.lg)
        fill.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: text]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let symbol = symbolImage?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [text]))
        let symbolWidth = symbol.map { ceil($0.size.width) + 6 } ?? 0
        var x = floor((bounds.width - symbolWidth - ceil(titleSize.width)) / 2)
        if let symbol {
            let symbolSize = symbol.size
            symbol.draw(
                in: NSRect(x: x, y: floor((bounds.height - symbolSize.height) / 2), width: symbolSize.width, height: symbolSize.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
            x += symbolWidth
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - titleSize.height) / 2), withAttributes: attributes)
        alphaValue = isHighlighted ? 0.9 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Agents' segmented control (the statistics range picker): a faint
/// `rounded-lg` track with the selected segment raised. Each segment is a
/// button, so VoiceOver reads them as a radio group.
final class SettingsSegmentedControl: NSControl {
    private(set) var selectedSegment: Int
    private var segments: [SettingsSegmentButton] = []

    init(titles: [String], selectedSegment: Int, target: AnyObject, action: Selector) {
        self.selectedSegment = selectedSegment
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Radius.lg
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        for (index, title) in titles.enumerated() {
            let segment = SettingsSegmentButton(title: title, target: self, action: #selector(segmentClicked(_:)))
            segment.tag = index
            segment.isActive = index == selectedSegment
            segments.append(segment)
            stack.addArrangedSubview(segment)
        }
        applyPalette()
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyPalette() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyPalette() {
        layer?.backgroundColor = PaletteCenter.shared.palette.foreground.withAlphaComponent(0.06).cgColor
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag != selectedSegment else { return }
        selectedSegment = sender.tag
        for segment in segments {
            segment.isActive = segment.tag == selectedSegment
        }
        sendAction(action, to: target)
    }
}

/// One segment (`h-6 rounded-md text-xs font-medium`): selected is the
/// popover fill with a faint input ring, hover the accent fill.
final class SettingsSegmentButton: NSButton {
    var isActive = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isActive)
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private static let font = Typography.ui(Typography.smallSize, weight: .medium)

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(false)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 20
        return NSSize(width: max(36, width), height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.md, yRadius: Radius.md)
        if isActive {
            palette.popover.setFill()
            path.fill()
            palette.input.withAlphaComponent(palette.input.alphaComponent * 0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHovered {
            palette.accent.setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isActive || isHovered ? palette.foreground : palette.mutedForeground,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: floor((bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
        alphaValue = isHighlighted ? 0.85 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

/// The Prefix key control, drawn as Agents' input box holding the prefix
/// chord (`⌃A`). Click it (or press Space) and type a key to make Control
/// plus that key the prefix; Esc keeps the current one.
final class SettingsPrefixKeyControl: NSControl, EscapeConsumingControl, KeyCapturingResponder {
    private(set) var key: String
    private var isRecording = false {
        didSet { refresh() }
    }

    var consumesEscape: Bool { isRecording }
    /// ⌃A, ⌃L, ⌃1… are exactly the keys a recording wants, so Soprano's
    /// chords step aside while it runs.
    var capturesKeys: Bool { isRecording }

    private var legend: String {
        isRecording ? "⌃…" : SettingsKeycaps.prefixLegend(key)
    }

    init(key: String, target: AnyObject, action: Selector) {
        self.key = key
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        toolTip = "Click, then press the key to use with Control"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Prefix key")
        refresh()
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let palette = PaletteCenter.shared.palette
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.lg, yRadius: Radius.lg)
        (palette.isDark ? palette.input.withAlphaComponent(palette.input.alphaComponent * 0.32) : palette.background).setFill()
        path.fill()
        (isRecording ? palette.primary.withAlphaComponent(0.7) : palette.input).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Typography.ui(Typography.bodySize),
            .foregroundColor: isRecording ? palette.mutedForeground : palette.foreground,
        ]
        let size = (legend as NSString).size(withAttributes: attributes)
        (legend as NSString).draw(
            at: NSPoint(x: floor((bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// A key view only under Full Keyboard Access; a click or an
    /// accessibility press still takes focus for the length of one recording.
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }

    override var acceptsFirstResponder: Bool { isEnabled && (isRecording || canBecomeKeyView) }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Radius.lg, yRadius: Radius.lg).fill()
    }

    /// Esc ends a recording and keeps the current prefix. The settings
    /// overlay steps aside while `consumesEscape`, so Esc reaches this
    /// key-equivalent pass.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording, event.keyCode == 53 {
            endRecording()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isRecording {
            endRecording()
        } else {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
        }
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.charactersIgnoringModifiers == " " {
                beginRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        // Esc keeps the current prefix.
        if event.keyCode == 53 {
            endRecording()
            return
        }
        guard let raw = event.charactersIgnoringModifiers,
              case let typed = raw.lowercased(),
              typed.count == 1,
              let scalar = typed.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.controlCharacters.contains(scalar),
              // Function keys (arrows, F-keys) live in the private-use range.
              !(0xF700...0xF8FF).contains(scalar.value),
              // The prefix matches Control alone, so a character that needs
              // Shift (⇧1 is "!") could never be typed. A shifted letter is
              // still that letter.
              !event.modifierFlags.contains(.shift) || typed != raw
        else {
            NSSound.beep()
            return
        }
        key = typed
        endRecording()
        sendAction(action, to: target)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func beginRecording() {
        guard isEnabled else { return }
        isRecording = true
        if let window, window.firstResponder !== self, !window.makeFirstResponder(self) {
            isRecording = false
        }
    }

    /// Without Full Keyboard Access the control is not a key view, so it
    /// hands focus back once the recording is over.
    private func endRecording() {
        isRecording = false
        if !canBecomeKeyView, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            isRecording = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refresh() {
        needsDisplay = true
        setAccessibilityValue(legend)
    }
}

/// A binding's keys as Agents' keycaps (`KbdView`, one per cap), with "or"
/// between alternatives (`⌘+ or ⌘=`).
final class SettingsKeycapsView: NSStackView {
    init(alternatives: [[String]]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        for (index, caps) in alternatives.enumerated() {
            if index > 0 {
                addArrangedSubview(SettingsLabel("or", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) })
            }
            let group = NSStackView(views: caps.map { KbdView($0) as NSView })
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 3
            addArrangedSubview(group)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(alternatives.map { $0.joined(separator: " ") }.joined(separator: " or "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
