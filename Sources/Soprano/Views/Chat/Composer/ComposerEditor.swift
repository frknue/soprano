import AppKit

/// The prompt editor: plain text at 14 pt with relaxed leading (1.625), at least two lines + 8 pt,
/// growing to 208 pt and then scrolling. Return sends, ⌘Return sends the other way (steers while
/// a turn runs), Shift-Return adds a newline, Up/Down in an empty editor walk the message
/// history, Escape goes to `onEscape`. While the `/` command menu shows, `menuKeyHandler` takes
/// its keys first. Pasted text arrives plain.
final class ComposerTextView: NSTextView {
    static let font = Typography.ui(Typography.bodySize)
    static let lineHeight: CGFloat = (Typography.bodySize * 1.625).rounded()
    static let minHeight: CGFloat = lineHeight * 2 + 8
    static let maxHeight: CGFloat = 208

    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { needsDisplay = true }
    }

    /// Return (alternate = ⌘Return).
    var onSubmit: ((_ alternate: Bool) -> Void)?
    /// Up (true) / Down (false). Returns true when it recalled history.
    var onHistory: ((_ up: Bool) -> Bool)?
    /// Escape. Returns true when it did something (closed a popover, stopped the turn).
    var onEscape: (() -> Bool)?
    /// Keys an open passive menu (the `/` command menu) or the question on screen takes before
    /// the editor. Returns true when handled.
    var menuKeyHandler: ((NSEvent) -> Bool)?
    /// The editor became (true) or stopped being (false) the first responder.
    var onFocusChange: ((Bool) -> Void)?
    /// True while `setText` replaces the text: a programmatic change, not typing.
    private(set) var isSettingText = false

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    static var baselineOffset: CGFloat {
        (lineHeight - (font.ascender - font.descender)) / 2 - 1
    }

    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle, .baselineOffset: baselineOffset]
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.minHeight), textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        // No system completions or inline predictive text: their ghost text lands in the message
        // ("/reThe") and Tab would accept them instead of picking from the `/` menu.
        isAutomaticTextCompletionEnabled = false
        inlinePredictionType = .no
        textContainerInset = .zero
        font = Self.font
        defaultParagraphStyle = Self.paragraphStyle
        typingAttributes = Self.textAttributes
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("Message")
    }

    /// Replaces the text, keeping the editor's attributes.
    func setText(_ text: String) {
        isSettingText = true
        defer { isSettingText = false }
        var attributes = Self.textAttributes
        attributes[.foregroundColor] = textColor ?? NSColor.textColor
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        typingAttributes = attributes
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        didChangeText()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            var attributes = Self.textAttributes
            attributes[.foregroundColor] = placeholderColor
            let origin = textContainerOrigin
            let rect = NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: bounds.height - origin.y)
            NSAttributedString(string: placeholder, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // While an input method composes marked text, its keys (↑/↓ candidates, Return commits,
        // Escape cancels) are the input method's, not the open menu's.
        if !hasMarkedText(), menuKeyHandler?(event) == true { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) {
            onSubmit?(true)
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true || NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?(false)
            }
        case #selector(moveUp(_:)):
            if onHistory?(true) != true { super.doCommand(by: selector) }
        case #selector(moveDown(_:)):
            if onHistory?(false) != true { super.doCommand(by: selector) }
        case #selector(cancelOperation(_:)):
            // Escape never opens NSTextView's completion list.
            _ = onEscape?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

/// Scroll container of the editor that sizes itself to the text (min two lines, max 208 pt).
final class ComposerEditorView: PaletteView {
    let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastWidth: CGFloat = 0

    /// Called when the editor's height changed.
    var onHeightChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        heightConstraint = heightAnchor.constraint(equalToConstant: ComposerTextView.minHeight)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
        textView.placeholderColor = palette.placeholder
        textView.selectedTextAttributes = [.backgroundColor: palette.primary.withAlphaComponent(0.25)]
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            textView.frame.size.width = scrollView.contentSize.width
            updateHeight()
        }
    }

    /// Re-measures the text and resizes between the minimum and 208 pt.
    func updateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(used.rounded(.up), ComposerTextView.minHeight), ComposerTextView.maxHeight)
        guard abs(height - heightConstraint.constant) > 0.5 else { return }
        heightConstraint.constant = height
        onHeightChange?()
    }
}
