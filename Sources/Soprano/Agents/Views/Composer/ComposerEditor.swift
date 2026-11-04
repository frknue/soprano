import AppKit
import SopranoAgentsCore

/// The prompt editor: plain text at 14 pt with relaxed leading (1.625), at least two
/// lines + 8 pt, growing to 208 pt and then scrolling. Enter sends, Shift+Enter adds a newline,
/// Up/Down in an empty editor walk the message history, Escape closes open pickers. While the
/// `/` command menu shows, `menuKeyHandler` takes its keys
/// first. Pasted or dropped files and images become attachments. Spelling and grammar marks
/// skip code (`ComposerProse`); a word completion shows as ghost text after the caret, Tab
/// accepts it with a space and → without (`ComposerWordCompletion`).
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

    /// Ghost-text completion of the word before the caret, drawn in the placeholder color. Shows
    /// only while the caret sits at the end of its line with nothing selected.
    var ghostText: String? {
        didSet { if ghostText != oldValue { needsDisplay = true } }
    }

    /// Enter (alternate = ⌘↩).
    var onSubmit: ((_ alternate: Bool) -> Void)?
    /// Up (true) / Down (false). Returns true when it recalled history.
    var onHistory: ((_ up: Bool) -> Bool)?
    /// Escape: closes an open picker.
    var onEscape: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onImageData: ((Data) -> Void)?
    var onDragHighlight: ((Bool) -> Void)?
    /// Keys an open passive menu (the `/` command menu) takes before the editor. Returns true when handled.
    var menuKeyHandler: ((NSEvent) -> Bool)?
    /// The editor stopped being the first responder.
    var onResignFocus: (() -> Void)?
    /// Tab (`space` true) or → while ghost text shows. Returns true when it inserted the completion.
    var onAcceptGhost: ((_ space: Bool) -> Bool)?
    /// The user is about to replace `range` with `text` (typing, paste, deletion, undo).
    var onWillChangeText: ((_ range: NSRange, _ text: String) -> Void)?
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
        // Spelling and grammar marks follow the provider's typo-detection setting
        // (`applyTextAssist`); autocorrect is off until that setting turns it on.
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        isAutomaticSpellingCorrectionEnabled = false
        // No system completions or inline predictive text: their ghost text lands in the message
        // ("/reThe") and Tab would accept them instead of picking from the `/` menu. Word
        // completion is the provider's (`ghostText`).
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
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityLabel("Message")
    }

    /// Spelling and grammar marks and autocorrect as the provider's settings have them.
    func applyTextAssist(_ preferences: TextAssistPreferences) {
        if isContinuousSpellCheckingEnabled != preferences.typoDetection {
            isContinuousSpellCheckingEnabled = preferences.typoDetection
        }
        if isGrammarCheckingEnabled != preferences.typoDetection {
            isGrammarCheckingEnabled = preferences.typoDetection
        }
        isAutomaticSpellingCorrectionEnabled = preferences.autocorrect
    }

    /// Code, paths and identifiers keep no spelling or grammar mark.
    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        let keep = value == 0 || ComposerProse.isProse(string as NSString, range: charRange)
        super.setSpellingState(keep ? value : 0, range: charRange)
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
        if let ghostText, let rect = ghostRect() {
            var attributes = Self.textAttributes
            attributes[.foregroundColor] = placeholderColor
            NSAttributedString(string: ghostText, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The line box from the caret to the view's right edge, while ghost text may show there.
    private func ghostRect() -> NSRect? {
        guard let layoutManager, let textContainer,
              let cursor = ComposerWordCompletion.cursor(in: string as NSString, selection: selectedRange()) else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: cursor - 1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let previous = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let origin = textContainerOrigin
        let x = origin.x + previous.maxX
        return NSRect(x: x, y: origin.y + line.minY, width: max(0, bounds.width - x), height: line.height)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if menuKeyHandler?(event) == true { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘↩ is `composer.sendAlternate`, which the keyboard router runs before this view sees the
        // key; unbound, it is just a newline-free no-op here like any other ⌘ chord.
        if (event.keyCode == 36 || event.keyCode == 76), flags.contains(.command) {
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            ghostText = nil
            onResignFocus?()
        }
        return resigned
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        onWillChangeText?(affectedCharRange, replacementString ?? "")
        return true
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
        case #selector(cancelOperation(_:)):
            // Escape closes an open picker; it never opens NSTextView's completion list.
            onEscape?()
        case #selector(insertTab(_:)):
            if onAcceptGhost?(true) != true { super.doCommand(by: selector) }
        case #selector(moveRight(_:)):
            if onAcceptGhost?(false) != true { super.doCommand(by: selector) }
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
