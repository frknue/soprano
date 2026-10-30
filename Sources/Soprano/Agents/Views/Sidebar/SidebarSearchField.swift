import AppKit
import SopranoAgentsCore

/// The sidebar's search field (`SidebarThreadHeader.tsx`): `h-8 rounded-md px-2 text-sm
/// font-medium`, search icon, placeholder "Search", clear button "Clear thread search".
/// Hover and focus fill it with the row-hover color; focus adds an inset ring.
final class SidebarSearchField: InteractiveView, NSTextFieldDelegate {
    let field = SearchTextField()
    private let icon = NSImageView()
    private let clearButton = RowActionButton(symbol: SidebarSymbol.xmark, symbolSize: 9, accessibility: "Clear thread search")
    private var isEditing: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    var onChange: ((String) -> Void)?
    /// Up / Down while editing (−1 / +1).
    var onMove: ((Int) -> Void)?
    /// Return while editing.
    var onSubmit: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set {
            guard newValue != field.stringValue else { return }
            field.stringValue = newValue
            updateClear()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(Icon.search, size: 13)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.font = Typography.ui(Typography.bodySize, weight: .medium)
        field.delegate = self
        field.setAccessibilityLabel("Search threads")
        // Focus changes settle after the field editor swaps in or out; read the state then.
        field.onFocusChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyPalette(self.palette)
                }
            }
        }
        clearButton.onClick = { [weak self] in
            guard let self else { return }
            text = ""
            onChange?("")
            field.requestFocus()
        }
        for view in [icon, field, clearButton] as [NSView] { addSubview(view) }
        updateClear()
        applyPalette(palette)
    }

    func focus() {
        field.requestFocus()
    }

    private func updateClear() {
        clearButton.isHidden = field.stringValue.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let clearWidth: CGFloat = clearButton.isHidden ? 0 : 20
        clearButton.frame = NSRect(x: bounds.width - 6 - clearWidth, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let fieldHeight = field.intrinsicContentSize.height
        let fieldX = icon.frame.maxX + 8
        field.frame = NSRect(x: fieldX, y: (bounds.height - fieldHeight) / 2, width: max(0, bounds.width - fieldX - 8 - clearWidth), height: fieldHeight)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func applyPalette(_ palette: Palette) {
        let active = isHovered || isEditing
        layer?.backgroundColor = (active ? palette.sidebarRowHover : .clear).cgColor
        layer?.borderWidth = isEditing ? 1 : 0
        layer?.borderColor = palette.primary.alphaScaled(by: 0.7).cgColor
        let tint = active ? palette.sidebarForeground : palette.sidebarMutedForeground
        icon.contentTintColor = palette.sidebarMutedForeground
        field.textColor = tint
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .foregroundColor: active ? palette.sidebarForeground.alphaScaled(by: 0.6) : palette.sidebarMutedForeground,
            .font: Typography.ui(Typography.bodySize, weight: .medium),
        ])
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateClear()
        applyPalette(palette)
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                window?.makeFirstResponder(nil)
            } else {
                text = ""
                onChange?("")
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            onMove?(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            onMove?(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        default:
            return false
        }
    }
}

/// Text field that reports when keyboard focus may have moved in or out.
final class SearchTextField: NSTextField {
    var onFocusChange: (() -> Void)?

    private var focusRequested = false

    /// Only a click or an explicit request focuses search: AppKit's automatic first-responder
    /// pick (window open, first key press) must never land here.
    override var acceptsFirstResponder: Bool {
        focusRequested || currentEditor() != nil || NSApp.currentEvent?.type == .leftMouseDown
    }

    override var canBecomeKeyView: Bool { false }

    func requestFocus() {
        focusRequested = true
        window?.makeFirstResponder(self)
        focusRequested = false
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}
