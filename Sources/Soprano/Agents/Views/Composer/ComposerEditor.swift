import AppKit

/// The prompt editor: plain text at 14 pt with T3 Code's relaxed leading (1.625), at least two
/// lines + 8 pt, growing to 208 pt and then scrolling. Enter sends, Shift+Enter adds a newline,
/// Up/Down in an empty editor walk the message history, Shift+Tab toggles plan mode, Escape
/// closes open pickers. Pasted or dropped files and images become attachments.
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

    /// Enter (alternate = ⌘↩).
    var onSubmit: ((_ alternate: Bool) -> Void)?
    /// Up (true) / Down (false). Returns true when it recalled history.
    var onHistory: ((_ up: Bool) -> Bool)?
    var onTogglePlan: (() -> Void)?
    /// Returns true when Escape closed something.
    var onEscape: (() -> Bool)?
    var onFiles: (([URL]) -> Void)?
    var onImageData: ((Data) -> Void)?
    var onDragHighlight: ((Bool) -> Void)?

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
        isContinuousSpellCheckingEnabled = false
        textContainerInset = .zero
        font = Self.font
        defaultParagraphStyle = Self.paragraphStyle
        typingAttributes = Self.textAttributes
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityLabel("Message")
    }

    /// Replaces the text, keeping the editor's attributes.
    func setText(_ text: String) {
        var attributes = Self.textAttributes
        attributes[.foregroundColor] = textColor ?? NSColor.textColor
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        typingAttributes = attributes
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        didChangeText()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        var attributes = Self.textAttributes
        attributes[.foregroundColor] = placeholderColor
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: bounds.height - origin.y)
        NSAttributedString(string: placeholder, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76), flags.contains(.command) {
            onSubmit?(true)
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?(false)
            }
        case #selector(moveUp(_:)):
            if onHistory?(true) != true { super.doCommand(by: selector) }
        case #selector(moveDown(_:)):
            if onHistory?(false) != true { super.doCommand(by: selector) }
        case #selector(insertBacktab(_:)):
            onTogglePlan?()
        case #selector(cancelOperation(_:)):
            if onEscape?() != true { super.doCommand(by: selector) }
        default:
            super.doCommand(by: selector)
        }
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        if consumeAttachments(from: NSPasteboard.general) { return }
        pasteAsPlainText(sender)
    }

    /// Files (file URLs) or raw image data on the pasteboard become attachments.
    @discardableResult
    func consumeAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        let hasText = pasteboard.availableType(from: [.string]) != nil
        if !hasText, let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            onImageData?(data)
            return true
        }
        return false
    }

    static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pasteboard.availableType(from: [.string]) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesAttachments(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        onDragHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesAttachments(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragHighlight?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragHighlight?(false)
        if consumeAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
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
